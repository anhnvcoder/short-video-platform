package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Hand-written govulncheck JSON streams, shaped like the output of govulncheck v1.9.0 (-format json): no network, no
// govulncheck run.
const (
	configMsg = `{"config":{"protocol_version":"v1.0.0","scanner_name":"govulncheck","scanner_version":"v1.9.0",` +
		`"db":"https://vuln.go.dev","db_last_modified":"2026-10-27T21:16:18Z","go_version":"go1.27.3",` +
		`"scan_level":"symbol","scan_mode":"source"}}`
	progressMsg = `{"progress":{"message":"Scanning your code and 312 packages across 61 dependent modules for known vulnerabilities..."}}`
	osvMsg      = `{"osv":{"schema_version":"1.3.1","id":"GO-2026-6809","summary":"Distrust compromised intermediate certificates in crypto/x509"}}`
	// Module level: the vulnerable module is in the build. Never called.
	moduleMsg = `{"finding":{"osv":"GO-2026-6866","fixed_version":"v0.62.0","trace":[{"module":"golang.org/x/net","version":"v0.60.0"}]}}`
	// Package level: the vulnerable package is imported. Never called.
	packageMsg = `{"finding":{"osv":"GO-2026-5932","trace":[{"module":"golang.org/x/crypto","version":"v0.58.0","package":"golang.org/x/crypto/openpgp"}]}}`
	// Module and package level of a vulnerability that is also called below: counted once, as called.
	calledModuleMsg = `{"finding":{"osv":"GO-2026-7001","trace":[{"module":"example.com/lib","version":"v1.2.3"}]}}`
	// Symbol level, no fix, reached through two paths: one failure.
	symbolMsg1 = `{"finding":{"osv":"GO-2026-7001","trace":[` +
		`{"module":"example.com/lib","version":"v1.2.3","package":"example.com/lib/parse","function":"Parse","position":{"filename":"parse/parse.go","line":40}},` +
		`{"module":"github.com/anhnvcoder/svp-backend","package":"github.com/anhnvcoder/svp-backend/internal/objstore","function":"Download","receiver":"*Store","position":{"filename":"internal/objstore/objstore.go","line":275}}]}}`
	symbolMsg2 = `{"finding":{"osv":"GO-2026-7001","trace":[` +
		`{"module":"example.com/lib","version":"v1.2.3","package":"example.com/lib/parse","function":"Parse","position":{"filename":"parse/parse.go","line":40}},` +
		`{"module":"github.com/anhnvcoder/svp-backend","package":"github.com/anhnvcoder/svp-backend/internal/pagetoken","function":"Decode","position":{"filename":"internal/pagetoken/pagetoken.go","line":12}}]}}`
	// Symbol level with a fix in the standard library.
	fixedSymbolMsg = `{"finding":{"osv":"GO-2026-6809","fixed_version":"v1.27.4","trace":[` +
		`{"module":"stdlib","version":"v1.27.3","package":"crypto/x509","function":"Verify","receiver":"*Certificate","position":{"filename":"src/crypto/x509/verify.go","line":548}},` +
		`{"module":"github.com/anhnvcoder/svp-backend","package":"github.com/anhnvcoder/svp-backend/internal/objstore","function":"Download","receiver":"*Store","position":{"filename":"internal/objstore/objstore.go","line":275}}]}}`

	goodDockerfile = "FROM golang:1.27.3-trixie@sha256:0000 AS build\nRUN go build ./...\n" +
		"FROM gcr.io/distroless/static-debian13:nonroot@sha256:1111\n"
)

var now = time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)

func stream(msgs ...string) string { return strings.Join(msgs, "\n") + "\n" }

func cleanStream() string { return stream(configMsg, progressMsg, osvMsg, moduleMsg, packageMsg) }

func calledStream() string {
	return stream(configMsg, progressMsg, osvMsg, moduleMsg, calledModuleMsg, symbolMsg1, symbolMsg2)
}

// entry is one valid exception for GO-2026-7001 in example.com/lib@v1.2.3, as JSON; tests edit its fields.
func entry(fields ...string) string {
	f := map[string]string{
		"id":         `"GO-2026-7001"`,
		"module":     `"example.com/lib"`,
		"version":    `"v1.2.3"`,
		"statement":  `"Parse only reads our own config; removed when the lib ships a fix."`,
		"expired_at": `"2026-11-20"`,
	}
	for i := 0; i+1 < len(fields); i += 2 {
		f[fields[i]] = fields[i+1]
	}
	var parts []string
	for _, k := range []string{"id", "module", "version", "statement", "expired_at"} {
		if f[k] != "" {
			parts = append(parts, `"`+k+`":`+f[k])
		}
	}
	return "{" + strings.Join(parts, ",") + "}"
}

func ignoreJSON(entries ...string) string { return `{"ignore":[` + strings.Join(entries, ",") + "]}" }

type setup struct {
	stdin       string
	ignore      *string // nil: no exception file
	dockerfiles map[string]string
}

func runGate(t *testing.T, s setup) (int, string) {
	t.Helper()
	dir := t.TempDir()
	ignorePath := filepath.Join(dir, ".govulncheck-ignore.json")
	if s.ignore != nil {
		if err := os.WriteFile(ignorePath, []byte(*s.ignore), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if s.dockerfiles == nil {
		s.dockerfiles = map[string]string{"service.Dockerfile": goodDockerfile}
	}
	var paths []string
	for name, content := range s.dockerfiles {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	var out strings.Builder
	code := run(strings.NewReader(s.stdin), &out, ignorePath, paths, now)
	return code, out.String()
}

func ptr(s string) *string { return &s }

func wantLines(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
}

func TestClean(t *testing.T) {
	code, out := runGate(t, setup{stdin: cleanStream()})
	if code != 0 {
		t.Fatalf("exit = %d, want 0:\n%s", code, out)
	}
	wantLines(t, out,
		"INFO  2 vulnerabilities in required modules, not called: GO-2026-5932 golang.org/x/crypto@v0.58.0, GO-2026-6866 golang.org/x/net@v0.60.0",
		"ok    govulncheck: no called vulnerability (go1.27.3, 1 golang images match, vuln.go.dev modified 2026-10-27T21:16:18Z)")
	if strings.Contains(out, "FAIL") {
		t.Errorf("clean stream printed a FAIL line:\n%s", out)
	}
}

func TestCalledWithoutException(t *testing.T) {
	code, out := runGate(t, setup{stdin: calledStream()})
	if code != 1 {
		t.Fatalf("exit = %d, want 1:\n%s", code, out)
	}
	wantLines(t, out,
		"FAIL  GO-2026-7001 example.com/lib@v1.2.3 (no fix)\n"+
			"        github.com/anhnvcoder/svp-backend/internal/objstore.(*Store).Download internal/objstore/objstore.go:275\n"+
			"        example.com/lib/parse.Parse parse/parse.go:40\n",
		// The called vulnerability is not counted again among the module-level ones.
		"INFO  1 vulnerabilities in required modules, not called: GO-2026-6866 golang.org/x/net@v0.60.0")
	if n := strings.Count(out, "FAIL  GO-2026-7001"); n != 1 {
		t.Errorf("GO-2026-7001 reported %d times, want once (two paths, one vulnerability):\n%s", n, out)
	}
	if strings.Contains(out, "ok    ") {
		t.Errorf("failing run printed the ok line:\n%s", out)
	}
}

func TestCalledWithFixShowsFixedVersion(t *testing.T) {
	code, out := runGate(t, setup{stdin: stream(configMsg, fixedSymbolMsg)})
	if code != 1 {
		t.Fatalf("exit = %d, want 1:\n%s", code, out)
	}
	wantLines(t, out, "FAIL  GO-2026-6809 stdlib@v1.27.3 (fixed in v1.27.4)",
		"        crypto/x509.(*Certificate).Verify src/crypto/x509/verify.go:548")
}

func TestValidException(t *testing.T) {
	code, out := runGate(t, setup{stdin: calledStream(), ignore: ptr(ignoreJSON(entry()))})
	if code != 0 {
		t.Fatalf("exit = %d, want 0:\n%s", code, out)
	}
	wantLines(t, out, "INFO  GO-2026-7001 example.com/lib@v1.2.3 ignored until 2026-11-20", "ok    govulncheck")
}

// TestExceptionFileErrors: every rule of the exception file fails the run, and an invalid entry silences nothing.
func TestExceptionFileErrors(t *testing.T) {
	tests := []struct {
		name   string
		stdin  string
		ignore string
		want   string
	}{
		{"expired", calledStream(), ignoreJSON(entry("expired_at", `"2026-10-28"`)),
			"entry 1 (GO-2026-7001): expired on 2026-10-28"},
		{"too far ahead", calledStream(), ignoreJSON(entry("expired_at", `"2026-11-28"`)),
			"entry 1 (GO-2026-7001): expired_at 2026-11-28 is more than 30 days ahead"},
		{"bad date", calledStream(), ignoreJSON(entry("expired_at", `"2026-11-5"`)),
			"entry 1 (GO-2026-7001): expired_at must be a date YYYY-MM-DD"},
		{"wrong version", calledStream(), ignoreJSON(entry("version", `"v1.2.4"`)),
			"entry 1 (GO-2026-7001): stale entry: no called vulnerability GO-2026-7001 example.com/lib@v1.2.4 in this scan"},
		{"wrong module", calledStream(), ignoreJSON(entry("module", `"example.com/other"`)),
			"entry 1 (GO-2026-7001): stale entry: no called vulnerability GO-2026-7001 example.com/other@v1.2.3 in this scan"},
		{"missing statement", calledStream(), ignoreJSON(entry("statement", "")),
			"entry 1 (GO-2026-7001): statement is empty"},
		{"blank statement", calledStream(), ignoreJSON(entry("statement", `"   "`)),
			"entry 1 (GO-2026-7001): statement is empty"},
		{"bad id", calledStream(), ignoreJSON(entry("id", `"CVE-2026-1"`)),
			"entry 1 (CVE-2026-1): id must look like GO-2026-0000"},
		{"bad version", calledStream(), ignoreJSON(entry("version", `"1.2.3"`)),
			"entry 1 (GO-2026-7001): version must be the module version of the finding"},
		{"missing module", calledStream(), ignoreJSON(entry("module", "")),
			"entry 1 (GO-2026-7001): module must be the module path of the finding"},
		{"unknown field", calledStream(), `{"ignore":[{"id":"GO-2026-7001","module":"example.com/lib","version":"v1.2.3",` +
			`"statement":"x","expired_at":"2026-11-20","until":"later"}]}`, `unknown field "until"`},
		{"unknown root key", calledStream(), `{"ignore":[` + entry() + `],"comment":"x"}`, `unknown field "comment"`},
		{"broken JSON", calledStream(), `{"ignore":[`, "unexpected EOF"},
		{"trailing data", calledStream(), ignoreJSON(entry()) + "{}", "data after the JSON object"},
		{"empty list", calledStream(), `{"ignore":[]}`, "no entries: delete the file"},
		{"no ignore key", calledStream(), `{}`, "no entries: delete the file"},
		{"duplicate", calledStream(), ignoreJSON(entry(), entry()), "entry 2 (GO-2026-7001): duplicate of entry 1"},
		{"stale extra entry", calledStream(), ignoreJSON(entry(), entry("id", `"GO-2026-7999"`)),
			"entry 2 (GO-2026-7999): stale entry"},
		{"not called", cleanStream(), ignoreJSON(entry("id", `"GO-2026-6866"`, "module", `"golang.org/x/net"`, "version", `"v0.60.0"`)),
			"entry 1 (GO-2026-6866): stale entry"},
		{"fix available", stream(configMsg, fixedSymbolMsg), ignoreJSON(entry("id", `"GO-2026-6809"`, "module", `"stdlib"`, "version", `"v1.27.3"`)),
			"entry 1 (GO-2026-6809): fix available in v1.27.4: upgrade instead"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, out := runGate(t, setup{stdin: tt.stdin, ignore: ptr(tt.ignore)})
			if code != 1 {
				t.Fatalf("exit = %d, want 1:\n%s", code, out)
			}
			wantLines(t, out, "FAIL  ", tt.want)
		})
	}
}

func TestInvalidEntryDoesNotSilence(t *testing.T) {
	code, out := runGate(t, setup{stdin: calledStream(), ignore: ptr(ignoreJSON(entry("expired_at", `"2026-10-01"`)))})
	if code != 1 {
		t.Fatalf("exit = %d, want 1:\n%s", code, out)
	}
	wantLines(t, out, "expired on 2026-10-01", "FAIL  GO-2026-7001 example.com/lib@v1.2.3 (no fix)")
}

func TestExpiryBoundaries(t *testing.T) {
	// The entry stops working at 00:00 UTC of expired_at; the last valid date is today + 30 days.
	for _, tt := range []struct {
		date string
		ok   bool
	}{{"2026-10-28", false}, {"2026-10-29", true}, {"2026-11-27", true}, {"2026-11-28", false}} {
		code, out := runGate(t, setup{stdin: calledStream(), ignore: ptr(ignoreJSON(entry("expired_at", `"`+tt.date+`"`)))})
		if (code == 0) != tt.ok {
			t.Errorf("expired_at %s: exit = %d, want ok=%v:\n%s", tt.date, code, tt.ok, out)
		}
	}
}

func TestDockerfiles(t *testing.T) {
	tests := []struct {
		name  string
		files map[string]string
		code  int
		want  string
	}{
		{"same release, flags and lower case", map[string]string{
			"a.Dockerfile": "from --platform=$BUILDPLATFORM golang:1.27.3-trixie@sha256:0 AS build\n",
			"b.Dockerfile": "FROM docker.io/library/golang:1.27.3 AS build\n",
			"c.Dockerfile": "FROM alpine:3.24@sha256:0 AS base\n",
		}, 0, "2 golang images match"},
		{"other release", map[string]string{"service.Dockerfile": "# builder\nFROM golang:1.27.4-trixie@sha256:0 AS build\n"}, 1,
			"service.Dockerfile:2: golang image is go1.27.4, govulncheck scanned go1.27.3 (go directive of go.mod): use one Go release in both"},
		{"minor only", map[string]string{"service.Dockerfile": "FROM golang:1.27-trixie AS build\n"}, 1,
			`golang image "golang:1.27-trixie" does not pin a patch release`},
		{"latest", map[string]string{"service.Dockerfile": "FROM golang:latest\n"}, 1, "does not pin a patch release"},
		{"digest only", map[string]string{"service.Dockerfile": "FROM golang@sha256:0\n"}, 1, "does not pin a patch release"},
		{"no golang stage", map[string]string{
			"c.Dockerfile": "FROM alpine:3.24@sha256:0 AS base\n",
			"x.Dockerfile": "FROM example.com/golang:1.27.3\n",
		}, 1, "no golang build stage in "},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, out := runGate(t, setup{stdin: cleanStream(), dockerfiles: tt.files})
			if code != tt.code {
				t.Fatalf("exit = %d, want %d:\n%s", code, tt.code, out)
			}
			wantLines(t, out, tt.want)
		})
	}
}

func TestNoDockerfileGiven(t *testing.T) {
	var out strings.Builder
	if code := run(strings.NewReader(cleanStream()), &out, filepath.Join(t.TempDir(), "absent.json"), nil, now); code != 1 {
		t.Fatalf("exit = %d, want 1:\n%s", code, out.String())
	}
	wantLines(t, out.String(), "FAIL  no golang build stage in no Dockerfile given")
}

func TestMissingDockerfile(t *testing.T) {
	var out strings.Builder
	dir := t.TempDir()
	code := run(strings.NewReader(cleanStream()), &out, filepath.Join(dir, "absent.json"),
		[]string{filepath.Join(dir, "gone.Dockerfile")}, now)
	if code != 1 {
		t.Fatalf("exit = %d, want 1:\n%s", code, out.String())
	}
	wantLines(t, out.String(), "gone.Dockerfile: no such file or directory")
}

func TestUnexpectedStream(t *testing.T) {
	tests := []struct{ name, stdin, want string }{
		{"empty", "", "no config message"},
		{"no config", stream(progressMsg, moduleMsg), "no config message"},
		{"other protocol", stream(strings.Replace(configMsg, `"v1.0.0"`, `"v2.0.0"`, 1)), `protocol version "v2.0.0"`},
		{"no go version", stream(strings.Replace(configMsg, `"go_version":"go1.27.3",`, "", 1)), "config has no go_version"},
		{"broken JSON", stream(configMsg, `{"finding":{"osv":`), "unexpected EOF"},
		{"empty trace", stream(configMsg, `{"finding":{"osv":"GO-2026-7001","trace":[]}}`), "finding GO-2026-7001 has no trace"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, out := runGate(t, setup{stdin: tt.stdin})
			if code != 1 {
				t.Fatalf("exit = %d, want 1:\n%s", code, out)
			}
			wantLines(t, out, "FAIL  unexpected govulncheck output: ", tt.want)
		})
	}
}
