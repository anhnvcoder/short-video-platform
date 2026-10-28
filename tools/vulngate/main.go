// Command vulngate decides the result of `govulncheck -format json`, which always exits 0 in JSON mode. It reads the
// JSON stream from stdin and exits 1 when:
//
//   - a vulnerability is reachable from the code (symbol level: the first frame of a finding names a function) and has
//     no valid entry in .govulncheck-ignore.json;
//   - .govulncheck-ignore.json is malformed, or one of its entries is expired, more than 30 days ahead, a duplicate,
//     stale (matches no called vulnerability) or covers a vulnerability that has a fix (upgrade instead);
//   - a `FROM golang:` line of a Dockerfile given as argument builds with another Go release than the one scanned,
//     or does not pin a patch release, or no Dockerfile given has a golang build stage at all: the scan of the source
//     only holds for the released binaries when they are built with the same Go;
//   - the stream is not what this gate understands (unknown protocol version, no config, broken JSON).
//
// Vulnerabilities in required modules or imported packages that the code does not call are only counted.
//
// Usage: govulncheck -format json ./... | go run ./tools/vulngate deploy/docker/*.Dockerfile
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	ignoreFile      = ".govulncheck-ignore.json"
	protocolVersion = "v1.0.0"
	// An entry lasts at most this long: a vulnerability without a fix can get one any day, so someone has to look
	// again every month.
	maxIgnoreDays = 30
)

func main() {
	var out strings.Builder
	code := run(os.Stdin, &out, ignoreFile, os.Args[1:], time.Now())
	_, _ = os.Stdout.WriteString(out.String())
	os.Exit(code)
}

// The subset of govulncheck's JSON protocol (golang.org/x/vuln/internal/govulncheck) the gate reads. Every message
// has exactly one field; osv, progress and SBOM messages decode to an empty message and are skipped.
type message struct {
	Config  *config  `json:"config"`
	Finding *finding `json:"finding"`
}

type config struct {
	ProtocolVersion string `json:"protocol_version"`
	DB              string `json:"db"`
	DBLastModified  string `json:"db_last_modified"`
	GoVersion       string `json:"go_version"`
}

type finding struct {
	OSV          string  `json:"osv"`
	FixedVersion string  `json:"fixed_version"`
	Trace        []frame `json:"trace"`
}

// A frame of a trace. The first frame is the vulnerable symbol (or only its module or package for findings at those
// levels), the last one the entry point in this repository.
type frame struct {
	Module   string    `json:"module"`
	Version  string    `json:"version"`
	Package  string    `json:"package"`
	Function string    `json:"function"`
	Receiver string    `json:"receiver"`
	Position *position `json:"position"`
}

type position struct {
	Filename string `json:"filename"`
	Line     int    `json:"line"`
}

// vulnKey names one vulnerability in one module version; a vulnerability reached through several paths is reported
// once per key.
type vulnKey struct{ id, module, version string }

func (k vulnKey) String() string { return k.id + " " + k.module + "@" + k.version }

type called struct {
	fixed string
	trace []frame
}

type ignoreEntry struct {
	ID        string `json:"id"`
	Module    string `json:"module"`
	Version   string `json:"version"`
	Statement string `json:"statement"`
	ExpiredAt string `json:"expired_at"`
}

var (
	osvID   = regexp.MustCompile(`^GO-[0-9]{4}-[0-9]{4,}$`)
	semver  = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+\S*$`)
	goPatch = regexp.MustCompile(`^([0-9]+\.[0-9]+\.[0-9]+)(-|$)`)
)

func run(stdin io.Reader, out *strings.Builder, ignorePath string, dockerfiles []string, now time.Time) int {
	cfg, symbols, notCalled, err := readStream(stdin)
	if err != nil {
		fmt.Fprintf(out, "FAIL  unexpected govulncheck output: %v\n", err)
		return 1
	}
	failed := false

	images, lines := checkDockerfiles(dockerfiles, cfg.GoVersion)
	for _, l := range lines {
		fmt.Fprintln(out, l)
		failed = true
	}

	ignored, lines := checkIgnoreFile(ignorePath, symbols, now)
	for _, l := range lines {
		fmt.Fprintln(out, l)
		failed = true
	}

	for _, k := range sortedKeys(symbols) {
		c := symbols[k]
		if e, ok := ignored[k]; ok {
			fmt.Fprintf(out, "INFO  %s ignored until %s (%s): %s\n", k, e.ExpiredAt, ignorePath, e.Statement)
			continue
		}
		failed = true
		fix := "no fix"
		if c.fixed != "" {
			fix = "fixed in " + c.fixed
		}
		fmt.Fprintf(out, "FAIL  %s (%s)\n", k, fix)
		// Entry point first, vulnerable symbol last: the order a reader follows the call.
		for i := len(c.trace) - 1; i >= 0; i-- {
			fmt.Fprintf(out, "        %s\n", frameString(c.trace[i]))
		}
	}

	var info []string
	for _, k := range sortedKeys(notCalled) {
		if _, ok := symbols[k]; !ok {
			info = append(info, k.String())
		}
	}
	if len(info) > 0 {
		fmt.Fprintf(out, "INFO  %d vulnerabilities in required modules, not called: %s\n", len(info), strings.Join(info, ", "))
	}

	if failed {
		return 1
	}
	fmt.Fprintf(out, "ok    govulncheck: no called vulnerability (%s, %d golang images match, %s modified %s)\n",
		cfg.GoVersion, images, strings.TrimPrefix(cfg.DB, "https://"), cfg.DBLastModified)
	return 0
}

// readStream splits the findings into symbol-level ones (the code calls the vulnerable function) and the others.
func readStream(r io.Reader) (*config, map[vulnKey]called, map[vulnKey]bool, error) {
	var cfg *config
	symbols := map[vulnKey]called{}
	notCalled := map[vulnKey]bool{}
	dec := json.NewDecoder(r)
	for {
		var m message
		if err := dec.Decode(&m); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, nil, nil, err
		}
		if m.Config != nil {
			cfg = m.Config
		}
		if f := m.Finding; f != nil {
			if len(f.Trace) == 0 {
				return nil, nil, nil, fmt.Errorf("finding %s has no trace", f.OSV)
			}
			top := f.Trace[0]
			k := vulnKey{f.OSV, top.Module, top.Version}
			if top.Function == "" {
				notCalled[k] = true
			} else if _, seen := symbols[k]; !seen {
				symbols[k] = called{fixed: f.FixedVersion, trace: f.Trace}
			}
		}
	}
	switch {
	case cfg == nil:
		return nil, nil, nil, errors.New("no config message")
	case cfg.ProtocolVersion != protocolVersion:
		return nil, nil, nil, fmt.Errorf("protocol version %q, this gate reads %s", cfg.ProtocolVersion, protocolVersion)
	case cfg.GoVersion == "":
		return nil, nil, nil, errors.New("config has no go_version")
	}
	return cfg, symbols, notCalled, nil
}

// checkDockerfiles compares the Go of every golang build stage with the Go release govulncheck scanned. It returns
// the number of matching stages and one FAIL line per problem.
func checkDockerfiles(paths []string, scanned string) (int, []string) {
	var fails []string
	stages, matched := 0, 0
	for _, path := range paths {
		f, err := os.Open(path) // #nosec G304 G703 -- the repository's Dockerfiles, given by the Makefile.
		if err != nil {
			fails = append(fails, fmt.Sprintf("FAIL  %v", err))
			continue
		}
		sc := bufio.NewScanner(f)
		for n := 1; sc.Scan(); n++ {
			ref, ok := fromImage(sc.Text())
			if !ok {
				continue
			}
			tag, ok := golangTag(ref)
			if !ok {
				continue
			}
			stages++
			m := goPatch.FindStringSubmatch(tag)
			switch {
			case m == nil:
				fails = append(fails, fmt.Sprintf("FAIL  %s:%d: golang image %q does not pin a patch release "+
					"(golang:1.27.3-trixie@sha256:…)", path, n, ref))
			case "go"+m[1] != scanned:
				fails = append(fails, fmt.Sprintf("FAIL  %s:%d: golang image is go%s, govulncheck scanned %s "+
					"(go directive of go.mod): use one Go release in both", path, n, m[1], scanned))
			default:
				matched++
			}
		}
		err = sc.Err()
		_ = f.Close()
		if err != nil {
			fails = append(fails, fmt.Sprintf("FAIL  %s: %v", path, err))
		}
	}
	if stages == 0 {
		given := "no Dockerfile given"
		if len(paths) > 0 {
			given = strings.Join(paths, ", ")
		}
		fails = append(fails, fmt.Sprintf("FAIL  no golang build stage in %s: the released Go cannot be checked", given))
	}
	return matched, fails
}

// fromImage returns the image reference of a FROM instruction, skipping flags such as --platform.
func fromImage(line string) (string, bool) {
	fields := strings.Fields(line)
	if len(fields) < 2 || !strings.EqualFold(fields[0], "FROM") {
		return "", false
	}
	for _, f := range fields[1:] {
		if !strings.HasPrefix(f, "--") {
			return f, true
		}
	}
	return "", false
}

// golangTag returns the tag of an official golang image reference ("" when it has none), and false for any other
// image.
func golangTag(ref string) (string, bool) {
	name, _, _ := strings.Cut(ref, "@")
	tag := ""
	if i := strings.LastIndex(name, ":"); i > strings.LastIndex(name, "/") {
		name, tag = name[:i], name[i+1:]
	}
	if name != "golang" && name != "docker.io/library/golang" {
		return "", false
	}
	return tag, true
}

// checkIgnoreFile validates the exception file and returns the entries that silence a called vulnerability. A
// missing file means no exception.
func checkIgnoreFile(path string, symbols map[vulnKey]called, now time.Time) (map[vulnKey]ignoreEntry, []string) {
	ignored := map[vulnKey]ignoreEntry{}
	data, err := os.ReadFile(path) // #nosec G304 -- the fixed exception file at the repository root.
	if errors.Is(err, fs.ErrNotExist) {
		return ignored, nil
	}
	if err != nil {
		return ignored, []string{fmt.Sprintf("FAIL  %s: %v", path, err)}
	}
	var file struct {
		Ignore []ignoreEntry `json:"ignore"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&file); err != nil {
		return ignored, []string{fmt.Sprintf("FAIL  %s: %v", path, err)}
	}
	if err := dec.Decode(&json.RawMessage{}); !errors.Is(err, io.EOF) {
		return ignored, []string{fmt.Sprintf("FAIL  %s: data after the JSON object", path)}
	}
	if len(file.Ignore) == 0 {
		return ignored, []string{fmt.Sprintf("FAIL  %s: no entries: delete the file", path)}
	}

	today := now.UTC().Truncate(24 * time.Hour)
	var fails []string
	seen := map[vulnKey]int{}
	for i, e := range file.Ignore {
		n := i + 1
		var reasons []string
		if !osvID.MatchString(e.ID) {
			reasons = append(reasons, "id must look like GO-2026-0000")
		}
		if e.Module == "" || strings.ContainsAny(e.Module, " \t\n") {
			reasons = append(reasons, `module must be the module path of the finding ("stdlib" for the standard library)`)
		}
		if !semver.MatchString(e.Version) {
			reasons = append(reasons, "version must be the module version of the finding (v1.2.3)")
		}
		if strings.TrimSpace(e.Statement) == "" {
			reasons = append(reasons, "statement is empty: say why the call is not exploitable here")
		}
		if exp, err := time.Parse(time.DateOnly, e.ExpiredAt); err != nil {
			reasons = append(reasons, "expired_at must be a date YYYY-MM-DD")
		} else if !exp.After(today) {
			reasons = append(reasons, "expired on "+e.ExpiredAt)
		} else if exp.After(today.AddDate(0, 0, maxIgnoreDays)) {
			reasons = append(reasons, fmt.Sprintf("expired_at %s is more than %d days ahead", e.ExpiredAt, maxIgnoreDays))
		}
		k := vulnKey{e.ID, e.Module, e.Version}
		if first, dup := seen[k]; dup {
			reasons = append(reasons, fmt.Sprintf("duplicate of entry %d", first))
		} else {
			seen[k] = n
		}
		if len(reasons) == 0 {
			c, ok := symbols[k]
			switch {
			case !ok:
				reasons = append(reasons, "stale entry: no called vulnerability "+k.String()+" in this scan")
			case c.fixed != "":
				reasons = append(reasons, "fix available in "+c.fixed+": upgrade instead")
			default:
				ignored[k] = e
			}
		}
		for _, r := range reasons {
			fails = append(fails, fmt.Sprintf("FAIL  %s: entry %d (%s): %s", path, n, e.ID, r))
		}
	}
	return ignored, fails
}

func frameString(f frame) string {
	name := f.Package
	if f.Receiver != "" {
		recv := f.Receiver
		if strings.HasPrefix(recv, "*") {
			recv = "(" + recv + ")"
		}
		name += "." + recv
	}
	if f.Function != "" {
		name += "." + f.Function
	}
	if f.Position != nil {
		name += fmt.Sprintf(" %s:%d", f.Position.Filename, f.Position.Line)
	}
	return name
}

func sortedKeys[V any](m map[vulnKey]V) []vulnKey {
	keys := make([]vulnKey, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].String() < keys[j].String() })
	return keys
}
