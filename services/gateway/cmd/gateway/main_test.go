package main

import (
	"testing"
)

func TestParseMediaBaseURL(t *testing.T) {
	for _, tc := range []struct {
		name, in, want string
		wantErr        bool
	}{
		{name: "http", in: "http://127.0.0.1:9000/media", want: "http://127.0.0.1:9000/media"},
		{name: "https cdn", in: "https://cdn.example.com", want: "https://cdn.example.com"},
		{name: "trailing slash is dropped", in: "http://127.0.0.1:9000/media/", want: "http://127.0.0.1:9000/media"},
		{name: "empty", in: "", wantErr: true},
		{name: "relative path", in: "/media", wantErr: true},
		{name: "no scheme", in: "127.0.0.1:9000/media", wantErr: true},
		{name: "unknown scheme", in: "ftp://example.com/media", wantErr: true},
		{name: "no host", in: "http:///media", wantErr: true},
		{name: "not a url", in: "http://[::1", wantErr: true},
		{name: "query", in: "http://127.0.0.1:9000/media?x=1", wantErr: true},
		{name: "empty query", in: "http://127.0.0.1:9000/media?", wantErr: true},
		{name: "fragment", in: "http://127.0.0.1:9000/media#x", wantErr: true},
		{name: "empty fragment", in: "http://127.0.0.1:9000/media#", wantErr: true},
		{name: "userinfo", in: "http://user:secret@127.0.0.1:9000/media", wantErr: true}, //nolint:gosec // fake userinfo is the case under test
		{name: "user only", in: "http://user@127.0.0.1:9000/media", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseMediaBaseURL(tc.in)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, tc.wantErr)
			}
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}
