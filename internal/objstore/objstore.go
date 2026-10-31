// Package objstore talks to the S3-compatible object storage (the local object store, S3 later)
// shared by video-service and media-worker: presigned POST forms for uploads and the HEAD, GET,
// PUT, DELETE and list calls on the uploads and media buckets. Clients send the file straight to
// storage with a presigned POST whose signed policy fixes the key and caps the size, so storage
// enforces the limit and the file never passes through a service.
//
// A key is the contract key verbatim, and its prefix picks the bucket: "uploads/<video_id>" lives
// in the uploads bucket, "media/<video_id>/..." in the media bucket.
package objstore

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/credentials/endpointcreds"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/anhnvcoder/short-video-platform/internal/envcfg"

	// Deprecated upstream, with no promise of further fixes; kept for now because it builds against
	// the pinned AWS SDK. Revisit it before upgrading the AWS SDK or moving to the cloud.
	"go.opentelemetry.io/contrib/instrumentation/github.com/aws/aws-sdk-go-v2/otelaws" //nolint:staticcheck // see above
)

// Key prefixes of the contract; each one maps to its own bucket.
const (
	UploadsPrefix = "uploads/"
	MediaPrefix   = "media/"
)

var (
	// ErrInvalidKey is returned for a key (or prefix) outside uploads/ and media/, or naming no
	// object under them.
	ErrInvalidKey = errors.New("objstore: key must start with uploads/ or media/ and name an object")
	// ErrNotFound is returned when the object (or its bucket) does not exist.
	ErrNotFound = errors.New("objstore: object not found")
	// ErrAccessDenied is returned when the credential may not do the operation. It is a
	// server-side configuration fault (credential or policy), not the caller's input, so callers
	// treat it as temporary and retry: fixing the policy makes the same call succeed.
	ErrAccessDenied = errors.New("objstore: access denied")
	// ErrTooLarge is returned by Download for an object larger than the limit.
	ErrTooLarge = errors.New("objstore: object larger than the limit")
	// ErrExists is returned by Create when the key already holds an object (HTTP 412).
	ErrExists = errors.New("objstore: object already exists")
)

// IsMediaKey reports whether key names an object of video videoID in the media bucket:
// "media/<videoID>/" followed by one or more segments, each made of letters, digits, ".", "_"
// and "-" only, and not "." or ".." (FF-6). The gateway puts the key into a URL as it is, and a
// URL parser reads "%2e%2e" as ".." and "\" as "/", so any other character could make a player
// resolve the URL elsewhere.
func IsMediaKey(key, videoID string) bool {
	rest, ok := strings.CutPrefix(key, MediaPrefix+videoID+"/")
	if !ok || rest == "" {
		return false
	}
	for seg := range strings.SplitSeq(rest, "/") {
		if seg == "" || seg == "." || seg == ".." || strings.ContainsFunc(seg, notKeyChar) {
			return false
		}
	}
	return true
}

func notKeyChar(r rune) bool {
	return (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '.' && r != '_' && r != '-'
}

// Credential modes, the values of S3_CREDENTIALS.
const (
	// CredentialsStatic signs with a fixed access key: the local object store, compose, k3d, tests.
	CredentialsStatic = "static"
	// CredentialsContainer signs with short-lived credentials fetched from the credential endpoint
	// of the container, as EKS Pod Identity hands them out: no long-lived key exists anywhere.
	CredentialsContainer = "container"
)

const (
	// maxPresignTTL is the longest life PresignPost gives a form.
	maxPresignTTL = 15 * time.Minute
	// credentialRefreshWindow is how long before its expiry a fetched credential stops signing
	// forms. A form stops working when the credential that signed it expires, so the window is
	// longer than the longest form, plus a margin for clock skew and the time the client takes to
	// start the upload: every form is signed with a credential that outlives it, as long as the
	// endpoint hands out credentials with more than this left.
	credentialRefreshWindow = maxPresignTTL + 5*time.Minute
	// callCredentialWindow is how long before its expiry a fetched credential stops signing calls
	// to storage. A call is used at once, so it only needs a margin for clock skew and the time the
	// request takes; the long window of forms would drop a credential that still works and turn a
	// failed refresh into failed calls 20 minutes early.
	callCredentialWindow = time.Minute
)

// Config holds what New needs; the services fill it from the S3_* variables, so the same image runs
// under compose, Kubernetes and the cloud with only the environment changing.
type Config struct {
	// Endpoint is the URL the service calls, e.g. http://s3:9000.
	Endpoint string
	// PublicEndpoint is the URL put into presigned forms, e.g. http://127.0.0.1:9000. Signing
	// does not call it. Empty means Endpoint.
	PublicEndpoint string
	Region         string
	// Credentials is CredentialsStatic (empty means the same) or CredentialsContainer.
	Credentials string
	// AccessKeyID and SecretAccessKey are the key of CredentialsStatic, and must be empty with
	// CredentialsContainer.
	AccessKeyID     string
	SecretAccessKey string
	// ContainerCredentialsURI and ContainerTokenFile are the credential endpoint and the file
	// holding the token sent to it, for CredentialsContainer only. The file is read on every fetch:
	// the token in it is rotated.
	ContainerCredentialsURI string
	ContainerTokenFile      string
	// VirtualHosted puts the bucket into the host name (https://<bucket>.s3.<region>.amazonaws.com),
	// the addressing S3 itself expects; false keeps path-style (<endpoint>/<bucket>), which the
	// local object store needs since its buckets have no host names of their own.
	VirtualHosted bool
	UploadsBucket string
	MediaBucket   string
}

// ReadAccessEnv fills in how c signs and addresses requests, from the environment:
//
//	S3_CREDENTIALS  static (default) or container
//	                static: S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are required
//	                container: AWS_CONTAINER_CREDENTIALS_FULL_URI and
//	                AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE are required (EKS Pod Identity sets
//	                both), and S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY must be unset
//	S3_PATH_STYLE   true (default) or false (virtual-hosted, for S3 itself)
//
// Errors name the variable, never its value.
func (c *Config) ReadAccessEnv() error {
	mode := envcfg.String("S3_CREDENTIALS", CredentialsStatic)
	switch mode {
	case CredentialsStatic:
		for _, r := range []struct {
			name string
			dst  *string
		}{{"S3_ACCESS_KEY_ID", &c.AccessKeyID}, {"S3_SECRET_ACCESS_KEY", &c.SecretAccessKey}} {
			v, err := envcfg.Required(r.name)
			if err != nil {
				return err
			}
			*r.dst = v
		}
	case CredentialsContainer:
		// A key left over would sit unused next to the credential actually used, and look like the
		// one that signs.
		for _, name := range []string{"S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"} {
			if envcfg.String(name, "") != "" {
				return fmt.Errorf("%s must not be set when S3_CREDENTIALS is %s", name, CredentialsContainer)
			}
		}
		uri, err := envcfg.Required("AWS_CONTAINER_CREDENTIALS_FULL_URI")
		if err != nil {
			return err
		}
		if err := checkContainerURI(uri); err != nil {
			return fmt.Errorf("AWS_CONTAINER_CREDENTIALS_FULL_URI %w", err)
		}
		tokenFile, err := envcfg.Required("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")
		if err != nil {
			return err
		}
		c.ContainerCredentialsURI, c.ContainerTokenFile = uri, tokenFile
	default:
		return fmt.Errorf("S3_CREDENTIALS must be %s or %s", CredentialsStatic, CredentialsContainer)
	}
	c.Credentials = mode

	switch envcfg.String("S3_PATH_STYLE", "true") {
	case "true":
		c.VirtualHosted = false
	case "false":
		c.VirtualHosted = true
	default:
		return errors.New("S3_PATH_STYLE must be true or false")
	}
	return nil
}

// The addresses of the EKS Pod Identity agent on every node.
var (
	podIdentityAgentIPv4 = netip.MustParseAddr("169.254.170.23")
	podIdentityAgentIPv6 = netip.MustParseAddr("fd00:ec2::23")
)

// checkContainerURI accepts only plain http to the EKS Pod Identity agent (169.254.170.23 or
// fd00:ec2::23) or to a loopback address (a narrower form of the check the AWS SDKs apply to this
// variable): the token goes out in the Authorization header, so a mistyped URI must not send it to
// any other host. The error does not carry the URI.
func checkContainerURI(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.User != nil {
		return errors.New("must be an http URL of the EKS Pod Identity agent or a loopback address")
	}
	ip, err := netip.ParseAddr(u.Hostname())
	if err != nil || (!ip.IsLoopback() && ip != podIdentityAgentIPv4 && ip != podIdentityAgentIPv6) {
		return errors.New("must name the EKS Pod Identity agent (169.254.170.23 or fd00:ec2::23) or a loopback address")
	}
	return nil
}

// Store reads and writes objects with one credential.
type Store struct {
	client        *s3.Client
	presign       *s3.PresignClient
	uploadsBucket string
	mediaBucket   string
	// listPageSize is the MaxKeys of each list request in DeletePrefix; 0 leaves the server
	// default (1000). Tests lower it to cross page boundaries.
	listPageSize int32
}

// New returns a Store for cfg. It does not connect; the first call does.
//
// Every call sent to the storage (HEAD, GET, PUT, DELETE, list) gets a client span from the
// global tracer provider, with the bucket and key as attributes, and carries the trace context
// in its headers. Signing a presigned form sends nothing to the storage and gets no span.
func New(cfg Config) (*Store, error) {
	required := []struct{ name, value string }{
		{"Endpoint", cfg.Endpoint},
		{"Region", cfg.Region},
		{"UploadsBucket", cfg.UploadsBucket},
		{"MediaBucket", cfg.MediaBucket},
	}
	for _, r := range required {
		if r.value == "" {
			return nil, fmt.Errorf("objstore: %s is empty", r.name)
		}
	}
	callCreds, formCreds, err := newCredentials(cfg)
	if err != nil {
		return nil, err
	}
	public := cfg.PublicEndpoint
	if public == "" {
		public = cfg.Endpoint
	}
	// Built from s3.Options rather than config.LoadDefaultConfig, which would also read
	// ~/.aws and the AWS_* variables and could pick up credentials other than the configured ones.
	opts := s3.Options{
		Region:                     cfg.Region,
		BaseEndpoint:               aws.String(cfg.Endpoint),
		UsePathStyle:               !cfg.VirtualHosted,
		Credentials:                callCreds,
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
		ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired,
	}
	client := s3.New(opts, func(o *s3.Options) { otelaws.AppendMiddlewares(&o.APIOptions) })
	// A second client only for signing: the SDK builds the form URL from the client's endpoint.
	// Without the tracing middleware: signing is local. It has its own credential cache, which
	// replaces a credential long before the one of calls does.
	publicClient := s3.New(opts, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(public)
		o.Credentials = formCreds
	})
	return &Store{
		client:        client,
		presign:       s3.NewPresignClient(publicClient),
		uploadsBucket: cfg.UploadsBucket,
		mediaBucket:   cfg.MediaBucket,
	}, nil
}

// newCredentials returns the credential providers of cfg.Credentials, one for calls to storage and
// one for signing forms, checking that exactly the fields of that mode are set.
func newCredentials(cfg Config) (calls, forms aws.CredentialsProvider, err error) {
	switch cfg.Credentials {
	case "", CredentialsStatic:
		if cfg.AccessKeyID == "" {
			return nil, nil, errors.New("objstore: AccessKeyID is empty")
		}
		if cfg.SecretAccessKey == "" {
			return nil, nil, errors.New("objstore: SecretAccessKey is empty")
		}
		static := credentials.NewStaticCredentialsProvider(cfg.AccessKeyID, cfg.SecretAccessKey, "")
		return static, static, nil
	case CredentialsContainer:
		if cfg.AccessKeyID != "" || cfg.SecretAccessKey != "" {
			return nil, nil, errors.New("objstore: AccessKeyID and SecretAccessKey must be empty with container credentials")
		}
		if cfg.ContainerTokenFile == "" {
			return nil, nil, errors.New("objstore: ContainerTokenFile is empty")
		}
		if err := checkContainerURI(cfg.ContainerCredentialsURI); err != nil {
			return nil, nil, fmt.Errorf("objstore: ContainerCredentialsURI %w", err)
		}
		tokenFile := cfg.ContainerTokenFile
		// No proxy: the token is for the agent alone, whatever HTTP_PROXY says.
		httpClient := awshttp.NewBuildableClient().WithTransportOptions(func(t *http.Transport) { t.Proxy = nil })
		provider := endpointcreds.New(cfg.ContainerCredentialsURI, func(o *endpointcreds.Options) {
			o.HTTPClient = httpClient
			o.AuthorizationTokenProvider = endpointcreds.TokenProviderFunc(func() (string, error) {
				token, err := os.ReadFile(tokenFile) //nolint:gosec // the path comes from the platform, not from a request
				if err != nil {
					return "", fmt.Errorf("read the container authorization token: %w", err)
				}
				return string(token), nil
			})
		})
		// Without a cache the SDK would fetch a credential for every request. Two caches, so each
		// keeps a credential for as long as its own use allows: a form must not outlive the
		// credential that signed it, a call only needs one valid while it is sent. Each cache
		// fetches once per credential lifetime.
		cache := func(window time.Duration) aws.CredentialsProvider {
			return aws.NewCredentialsCache(provider, func(o *aws.CredentialsCacheOptions) { o.ExpiryWindow = window })
		}
		return cache(callCredentialWindow), cache(credentialRefreshWindow), nil
	default:
		return nil, nil, fmt.Errorf("objstore: Credentials must be %s or %s", CredentialsStatic, CredentialsContainer)
	}
}

// bucket returns the bucket holding key, which must have something after its prefix.
func (s *Store) bucket(key string) (string, error) {
	switch {
	case strings.HasPrefix(key, UploadsPrefix) && len(key) > len(UploadsPrefix):
		return s.uploadsBucket, nil
	case strings.HasPrefix(key, MediaPrefix) && len(key) > len(MediaPrefix):
		return s.mediaBucket, nil
	default:
		return "", ErrInvalidKey
	}
}

// PresignedPost is an HTML form upload: POST URL as multipart/form-data with every field in
// Fields, then the file in a last field named "file". URL and Fields grant write access until
// ExpiresAt: never log them.
type PresignedPost struct {
	URL       string
	Fields    map[string]string
	ExpiresAt time.Time
}

// PresignPost signs a form that lets its holder write exactly key, with a body of 1 to
// sizeBytes bytes and Content-Type contentType, until ttl from now (UP-1); ttl is at most 15
// minutes. Only keys under uploads/ can be signed. Signing is local: nothing is sent, except that
// with container credentials the first form, and one after each refresh, fetches a credential.
func (s *Store) PresignPost(ctx context.Context, key string, sizeBytes int64, contentType string, ttl time.Duration) (*PresignedPost, error) {
	if !strings.HasPrefix(key, UploadsPrefix) {
		return nil, ErrInvalidKey
	}
	bucket, err := s.bucket(key)
	if err != nil {
		return nil, err
	}
	if sizeBytes < 1 || contentType == "" || ttl <= 0 || ttl > maxPresignTTL {
		return nil, fmt.Errorf("objstore: presign needs a size of at least 1, a content type and a ttl of at most %s", maxPresignTTL)
	}
	req, err := s.presign.PresignPostObject(ctx, &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)},
		func(o *s3.PresignPostOptions) {
			o.Expires = ttl
			// The SDK adds an exact key condition only when none is given; giving it here keeps
			// the exact match whatever the SDK does. Never add ["starts-with", "$key", ...].
			o.Conditions = []any{
				map[string]string{"key": key},
				map[string]string{"Content-Type": contentType},
				[]any{"content-length-range", 1, sizeBytes},
			}
		})
	if err != nil {
		return nil, fmt.Errorf("objstore: presign post: %w", err)
	}
	expiresAt, err := policyExpiration(req.Values["policy"])
	if err != nil {
		return nil, err
	}
	fields := make(map[string]string, len(req.Values)+1)
	for k, v := range req.Values {
		fields[k] = v
	}
	// The policy requires Content-Type to match but the SDK does not return it as a form field; without it storage
	// would reject the form.
	fields["Content-Type"] = contentType
	return &PresignedPost{URL: req.URL, Fields: fields, ExpiresAt: expiresAt}, nil
}

// policyExpiration reads the expiration the SDK signed into a base64 POST policy.
func policyExpiration(policy string) (time.Time, error) {
	raw, err := base64.StdEncoding.DecodeString(policy)
	if err != nil {
		return time.Time{}, fmt.Errorf("objstore: decode post policy: %w", err)
	}
	var doc struct {
		Expiration time.Time `json:"expiration"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return time.Time{}, fmt.Errorf("objstore: decode post policy: %w", err)
	}
	return doc.Expiration, nil
}

// ObjectInfo is what Head reports about an object.
type ObjectInfo struct {
	Size        int64
	ContentType string
}

// Head returns the size and content type of key, or ErrNotFound.
func (s *Store) Head(ctx context.Context, key string) (ObjectInfo, error) {
	bucket, err := s.bucket(key)
	if err != nil {
		return ObjectInfo{}, err
	}
	out, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		return ObjectInfo{}, classify("head "+key, err)
	}
	return ObjectInfo{Size: aws.ToInt64(out.ContentLength), ContentType: aws.ToString(out.ContentType)}, nil
}

// Download streams key into the file at path, created or truncated. An object larger than
// maxBytes fails with ErrTooLarge; on any error the file is removed, including one an earlier
// attempt left at path.
func (s *Store) Download(ctx context.Context, key, path string, maxBytes int64) (err error) {
	defer func() {
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	bucket, err := s.bucket(key)
	if err != nil {
		return err
	}
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		return classify("download "+key, err)
	}
	defer func() { _ = out.Body.Close() }()
	if aws.ToInt64(out.ContentLength) > maxBytes {
		return fmt.Errorf("download %s: %w", key, ErrTooLarge)
	}

	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600) //nolint:gosec // the caller picks a path in its own work directory
	if err != nil {
		return fmt.Errorf("objstore: download %s: %w", key, err)
	}
	defer func() {
		if cerr := f.Close(); err == nil && cerr != nil {
			err = fmt.Errorf("objstore: download %s: %w", key, cerr)
		}
	}()
	// The length header can be missing; reading one byte past the limit is the real check.
	n, err := io.Copy(f, io.LimitReader(out.Body, maxBytes+1))
	if err != nil {
		return fmt.Errorf("objstore: download %s: %w", key, err)
	}
	if n > maxBytes {
		return fmt.Errorf("download %s: %w", key, ErrTooLarge)
	}
	return nil
}

// Upload writes the file at path to key with the given content type, and with header
// Cache-Control set to cacheControl unless it is empty. Storage keeps both and sends them back
// with every GET of the object.
func (s *Store) Upload(ctx context.Context, key, path, contentType, cacheControl string) error {
	return s.put(ctx, key, path, contentType, cacheControl, false)
}

// Create is Upload that only writes when key holds no object yet (If-None-Match: *); otherwise it
// returns ErrExists and leaves the object as it is. Storage lets exactly one of several creates
// of the same key succeed.
func (s *Store) Create(ctx context.Context, key, path, contentType, cacheControl string) error {
	return s.put(ctx, key, path, contentType, cacheControl, true)
}

func (s *Store) put(ctx context.Context, key, path, contentType, cacheControl string, create bool) error {
	bucket, err := s.bucket(key)
	if err != nil {
		return err
	}
	f, err := os.Open(path) //nolint:gosec // the caller picks a path in its own work directory
	if err != nil {
		return fmt.Errorf("objstore: upload %s: %w", key, err)
	}
	defer func() { _ = f.Close() }()
	st, err := f.Stat()
	if err != nil {
		return fmt.Errorf("objstore: upload %s: %w", key, err)
	}
	in := &s3.PutObjectInput{
		Bucket:        aws.String(bucket),
		Key:           aws.String(key),
		Body:          f,
		ContentLength: aws.Int64(st.Size()),
		ContentType:   aws.String(contentType),
	}
	if cacheControl != "" {
		in.CacheControl = aws.String(cacheControl)
	}
	if create {
		in.IfNoneMatch = aws.String("*")
	}
	if _, err := s.client.PutObject(ctx, in); err != nil {
		return classify("upload "+key, err)
	}
	return nil
}

// Exists reports whether key holds an object, by listing the keys that start with key. Unlike
// HEAD, which S3 answers with 403 instead of 404 when the credential may not list the bucket, a
// missing key is an empty list, so "no" is never mistaken for a denied call: any error, 403
// included, is returned as one.
func (s *Store) Exists(ctx context.Context, key string) (bool, error) {
	bucket, err := s.bucket(key)
	if err != nil {
		return false, err
	}
	// Keys sort by bytes, so key itself comes before every longer key it starts.
	out, err := s.client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket), Prefix: aws.String(key), MaxKeys: aws.Int32(1),
	})
	if err != nil {
		return false, classify("list "+key, err)
	}
	return len(out.Contents) > 0 && aws.ToString(out.Contents[0].Key) == key, nil
}

// Delete removes key; a key that does not exist is not an error.
func (s *Store) Delete(ctx context.Context, key string) error {
	bucket, err := s.bucket(key)
	if err != nil {
		return err
	}
	if _, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)}); err != nil {
		if err = classify("delete "+key, err); !errors.Is(err, ErrNotFound) {
			return err
		}
	}
	return nil
}

// DeletePrefix removes every object whose key starts with prefix, e.g. "media/<video_id>/". The
// prefix must end with "/" so that "media/1/" cannot also take "media/10/...". Nothing under
// it is not an error.
func (s *Store) DeletePrefix(ctx context.Context, prefix string) error {
	bucket, err := s.bucket(prefix)
	if err != nil {
		return err
	}
	if !strings.HasSuffix(prefix, "/") {
		return ErrInvalidKey
	}
	in := &s3.ListObjectsV2Input{Bucket: aws.String(bucket), Prefix: aws.String(prefix)}
	if s.listPageSize > 0 {
		in.MaxKeys = aws.Int32(s.listPageSize)
	}
	pages := s3.NewListObjectsV2Paginator(s.client, in)
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return classify("list "+prefix, err)
		}
		// One DeleteObject per key: a few hundred HLS files per video at most, and each failure
		// is classified like any other call.
		for _, obj := range page.Contents {
			if err := s.Delete(ctx, aws.ToString(obj.Key)); err != nil {
				return err
			}
		}
	}
	return nil
}

// classify wraps an SDK error so that errors.Is finds ErrNotFound (HTTP 404), ErrAccessDenied
// (HTTP 403) or ErrExists (HTTP 412, only a create sends a precondition); anything else (5xx,
// network, timeout, 409 when a delete of the same key ran first) is treated as temporary by the
// callers.
func classify(op string, err error) error {
	var re *awshttp.ResponseError
	if errors.As(err, &re) {
		switch re.HTTPStatusCode() {
		case http.StatusNotFound:
			return fmt.Errorf("%s: %w: %w", op, ErrNotFound, err)
		case http.StatusForbidden:
			return fmt.Errorf("%s: %w: %w", op, ErrAccessDenied, err)
		case http.StatusPreconditionFailed:
			return fmt.Errorf("%s: %w: %w", op, ErrExists, err)
		}
	}
	return fmt.Errorf("objstore: %s: %w", op, err)
}
