package secret

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"testing"
)

const value = "hunter2-super-secret"

func TestRevealReturnsValue(t *testing.T) {
	if got := New(value).Reveal(); got != value {
		t.Errorf("Reveal() = %q, want %q", got, value)
	}
	if got := (String{}).Reveal(); got != "" {
		t.Errorf("zero Reveal() = %q, want empty", got)
	}
}

func TestFmtDoesNotLeak(t *testing.T) {
	s := New(value)
	type exported struct{ Password String }
	type unexported struct{ password String }
	outputs := []string{
		fmt.Sprintf("%v %s %+v %#v %q %x %d", s, s, s, s, s, s, s),
		fmt.Sprint(s),
		fmt.Sprintf("%v %+v %#v", exported{s}, exported{s}, &exported{s}),
		fmt.Sprintf("%v %+v %#v", unexported{s}, unexported{s}, &unexported{s}),
		fmt.Errorf("login failed for %v", s).Error(),
	}
	for _, out := range outputs {
		if strings.Contains(out, value) {
			t.Errorf("output leaks the secret: %s", out)
		}
	}
	if got := fmt.Sprintf("%v", s); got != redacted {
		t.Errorf("%%v = %q, want %q", got, redacted)
	}
}

func TestSlogDoesNotLeak(t *testing.T) {
	s := New(value)
	var buf bytes.Buffer
	for _, h := range []slog.Handler{slog.NewJSONHandler(&buf, nil), slog.NewTextHandler(&buf, nil)} {
		logger := slog.New(h)
		logger.Info("login", "password", s, slog.Any("token", s), slog.Group("req", "password", s))
		logger.Info("login", "req", struct{ Password String }{s})
	}
	out := buf.String()
	if strings.Contains(out, value) {
		t.Errorf("log leaks the secret: %s", out)
	}
	if !strings.Contains(out, redacted) {
		t.Errorf("log does not contain the placeholder: %s", out)
	}
}

func TestJSONDoesNotLeak(t *testing.T) {
	out, err := json.Marshal(struct {
		Password String `json:"password"`
	}{New(value)})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(out), `{"password":"[REDACTED]"}`; got != want {
		t.Errorf("json.Marshal = %s, want %s", got, want)
	}
}
