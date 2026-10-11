// Package secret holds passwords and tokens in a type that prints as [REDACTED] through fmt,
// log/slog and encoding/json, so a value that ends up in a log line or an error does not leak
// (threat model JWT-8).
package secret

import (
	"fmt"
	"io"
	"log/slog"
)

const redacted = "[REDACTED]"

// String is a secret string. The zero value is the empty secret. The only way to read the value
// is Reveal.
//
// The value sits behind a pointer so that printing a struct that holds a String in an
// unexported field, where fmt cannot call the methods below, shows an address and not the value.
type String struct {
	p *string
}

// New wraps v.
func New(v string) String {
	return String{p: &v}
}

// Reveal returns the secret value. Call it only where the value is used (hashing, signing,
// writing the response), never to log it.
func (s String) Reveal() string {
	if s.p == nil {
		return ""
	}
	return *s.p
}

// String implements fmt.Stringer.
func (String) String() string { return redacted }

// GoString implements fmt.GoStringer (%#v).
func (String) GoString() string { return redacted }

// Format implements fmt.Formatter, so every verb (%x and %q included) prints the placeholder.
func (String) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, redacted) }

// LogValue implements slog.LogValuer.
func (String) LogValue() slog.Value { return slog.StringValue(redacted) }

// MarshalJSON implements json.Marshaler.
func (String) MarshalJSON() ([]byte, error) { return []byte(`"` + redacted + `"`), nil }
