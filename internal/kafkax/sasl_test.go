package kafkax

// SCRAM-SHA-256 from KAFKA_SASL_USERNAME and KAFKA_SASL_PASSWORD. The tests set the environment
// with t.Setenv, so none of them runs in parallel.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
)

const (
	saslUser = "svc-user"
	saslPass = "s3cret-scram-pass"
)

// saslCluster starts an in-memory Kafka that accepts only SCRAM-SHA-256 as saslUser with
// saslPass, with one-partition topics and the extra opts, and returns it with its broker list.
func saslCluster(t *testing.T, topics []string, opts ...kfake.Opt) (*kfake.Cluster, string) {
	t.Helper()
	c, err := kfake.NewCluster(append([]kfake.Opt{kfake.NumBrokers(1), kfake.SeedTopics(1, topics...),
		kfake.EnableSASL(), kfake.Superuser("SCRAM-SHA-256", saslUser, saslPass)}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c, strings.Join(c.ListenAddrs(), ",")
}

// With the right credentials every client NewClient builds authenticates: a producer, a group
// consumer and the dead-letter producer inside it, and a reader.
func TestSASLRightPassword(t *testing.T) {
	_, brokers := saslCluster(t, []string{"in", "in.dlq"})
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, saslPass)

	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})
	start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(context.Context, *kgo.Record, Attempt) error {
			return Permanent(errors.New("bad event"))
		}})

	dlq := readTopic(t, brokers, "in.dlq", 1, 15*time.Second)
	if len(dlq) != 1 || string(dlq[0].Value) != "bad" {
		t.Fatalf("dead-letter topic = %v, want the record the consumer read", dlq)
	}
}

// countSASLAuthenticate counts the SASLAuthenticate requests c receives from now on, leaving
// their handling to c.
func countSASLAuthenticate(c *kfake.Cluster) *atomic.Int32 {
	var n atomic.Int32
	c.ControlKey(int16(kmsg.SASLAuthenticate), func(kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		n.Add(1)
		return nil, nil, false
	})
	return &n
}

// With a wrong password kfake checks the SCRAM proof, fails it with "invalid password" and drops
// the connection. franz-go takes that as a broken connection and retries it with backoff, so
// Produce fails at its deadline, not earlier with an authentication error; neither its error nor
// the client's debug log carries a password. A Kafka broker answers the proof with an error
// instead, which the client logs: TestSASLAuthenticationFailedIsLogged.
func TestSASLWrongPassword(t *testing.T) {
	brokerLog := &lockedBuffer{}
	_, brokers := saslCluster(t, []string{"out"}, kfake.WithLogger(kfake.BasicLogger(brokerLog, kfake.LogLevelInfo)))
	const wrong = "wrong-scram-pass"
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, wrong)
	logs := &lockedBuffer{}
	cl, err := NewClient(brokers, "test-producer", kgo.WithLogger(kgo.BasicLogger(logs, kgo.LogLevelDebug, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	const deadline = time.Second
	ctx, cancel := context.WithTimeout(t.Context(), deadline)
	defer cancel()

	started := time.Now()
	err = produceWithin(t, 10*time.Second, ctx, cl, &kgo.Record{Topic: "out", Value: []byte("v")})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	if elapsed, limit := time.Since(started), deadline+2*time.Second; elapsed > limit {
		t.Errorf("Produce() returned after %v, want at most %v", elapsed, limit)
	}
	// kfake returns this error only once the proof does not match the stored SCRAM key, so the
	// client got through the whole exchange and the broker refused the password itself.
	if !strings.Contains(brokerLog.String(), "request unable to be handled: invalid password") {
		t.Errorf("the broker never refused the SCRAM proof; its log:\n%s", brokerLog)
	}
	if err != nil && strings.Contains(err.Error(), wrong) {
		t.Errorf("Produce() error %q carries the password", err)
	}
	if strings.Contains(logs.String(), wrong) {
		t.Error("the client's debug log carries the password")
	}
}

// answerAuthenticationFailed makes c answer the client's SCRAM proof with
// SASL_AUTHENTICATION_FAILED, as a Kafka broker answers a wrong password (KIP-152: every
// SaslAuthenticate request gets a response, a failed one an error code and message).
func answerAuthenticationFailed(c *kfake.Cluster) {
	c.ControlKey(int16(kmsg.SASLAuthenticate), func(kr kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		req := kr.(*kmsg.SASLAuthenticateRequest)
		// The client-final-message, the one carrying the proof, starts with its channel binding;
		// kfake handles the client-first-message as usual.
		if !bytes.HasPrefix(req.SASLAuthBytes, []byte("c=")) {
			return nil, nil, false
		}
		resp := req.ResponseKind().(*kmsg.SASLAuthenticateResponse)
		resp.ErrorCode = kerr.SaslAuthenticationFailed.Code
		msg := "Authentication failed: invalid credentials"
		resp.ErrorMessage = &msg
		return resp, nil, true
	})
}

// A broker refusing the credentials shows in the service's log: through the default slog logger
// the client logs an ERROR naming SASL_AUTHENTICATION_FAILED for each attempt, at franz-go's
// retry backoff, and neither that log nor Produce's error carries the password.
func TestSASLAuthenticationFailedIsLogged(t *testing.T) {
	c, brokers := saslCluster(t, []string{"out"})
	answerAuthenticationFailed(c)
	const wrong = "wrong-scram-pass"
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, wrong)
	logs := defaultLogs(t)
	cl := producer(t, brokers)
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()

	err := produceWithin(t, 10*time.Second, ctx, cl, &kgo.Record{Topic: "out", Value: []byte("v")})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	failures := logs.records(t, "kafka client: unable to initialize sasl")
	// Measured: 6 in 10 s, the backoff growing after each attempt; a client retrying in a tight
	// loop would log thousands.
	if n := len(failures); n == 0 || n > 10 {
		t.Errorf("%d SASL failures logged in %v, want some, at most 10", n, time.Second)
	}
	for _, rec := range failures {
		if rec["level"] != "ERROR" || !strings.Contains(fmt.Sprint(rec["err"]), "SASL_AUTHENTICATION_FAILED") {
			t.Errorf("SASL failure logged as %v, want an ERROR naming SASL_AUTHENTICATION_FAILED", rec)
		}
	}
	if strings.Contains(logs.String(), wrong) {
		t.Error("the log carries the password")
	}
	if err != nil && strings.Contains(err.Error(), wrong) {
		t.Errorf("Produce() error %q carries the password", err)
	}
}

// A consumer with a wrong password retries authentication at the client's backoff instead of
// spinning, handles nothing, and stops cleanly when asked.
func TestSASLWrongPasswordConsumerBacksOff(t *testing.T) {
	c, brokers := saslCluster(t, []string{"in", "in.dlq"})
	t.Setenv(saslUsernameVar, saslUser)
	t.Setenv(saslPasswordVar, "wrong-scram-pass")
	attempts := countSASLAuthenticate(c)
	var calls atomic.Int32
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(context.Context, *kgo.Record, Attempt) error {
			calls.Add(1)
			return nil
		}})

	const window = 3 * time.Second
	time.Sleep(window)
	// Measured: about 6 a second, paced by franz-go's retry backoff; a client spinning on the
	// error would make thousands.
	if n := attempts.Load(); n == 0 || n > 60 {
		t.Errorf("%d SASL authentications in %v, want some, at most 60", n, window)
	}
	if err := r.stop(t); err != nil {
		t.Errorf("Run() = %v, want nil once stopped", err)
	}
	if n := calls.Load(); n != 0 {
		t.Errorf("handler called %d times without an authenticated connection", n)
	}
}

// Only one of the two variables set: NewClient fails, naming the missing variable and carrying
// no value. An empty variable counts as unset.
func TestNewClientSASLMissingVariable(t *testing.T) {
	tests := []struct {
		name, user, pass, missing string
	}{
		{"password unset", saslUser, "", saslPasswordVar},
		{"username unset", "", saslPass, saslUsernameVar},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(saslUsernameVar, tt.user)
			t.Setenv(saslPasswordVar, tt.pass)
			cl, err := NewClient("127.0.0.1:9092", "svc")
			if err == nil {
				cl.Close()
				t.Fatal("NewClient() = nil error, want the missing variable")
			}
			if msg := err.Error(); !strings.Contains(msg, tt.missing+" is not") ||
				strings.Contains(msg, saslPass) || strings.Contains(msg, saslUser) {
				t.Errorf("NewClient() error = %q, want it to name %s and carry no value", msg, tt.missing)
			}
		})
	}
}

// Both variables set but empty count as unset: no SASL, so a broker without authentication, as
// on the compose stack, takes the client.
func TestNewClientSASLEmptyVariables(t *testing.T) {
	t.Setenv(saslUsernameVar, "")
	t.Setenv(saslPasswordVar, "")
	produce(t, producer(t, cluster(t, 1, "out")), &kgo.Record{Topic: "out", Value: []byte("v")})
}
