// Command jwtkey prints a new Ed25519 JWT key pair as the three environment variable lines that
// `make env` appends to .env:
//
//	JWT_SIGNING_KID=<kid>
//	JWT_SIGNING_KEY=<standard base64 of the 32-byte seed>
//	JWT_VERIFY_KEYS=<kid>:<standard base64 of the 32-byte public key>
//
// The kid is the UTC date plus 4 random bytes in hex (e.g. 20261011-3fa2c91b): the date shows
// how old a key is when rotating, the random part keeps two keys made on the same day apart.
//
// It writes only to stdout, never to a file.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
)

func main() {
	if err := run(os.Stdout, time.Now()); err != nil {
		fmt.Fprintln(os.Stderr, "jwtkey:", err)
		os.Exit(1)
	}
}

func run(w io.Writer, now time.Time) error {
	key, err := authtoken.GenerateKey()
	if err != nil {
		return err
	}
	suffix := make([]byte, 4)
	_, _ = rand.Read(suffix) // crypto/rand.Read never returns an error (Go 1.24+).
	kid := now.UTC().Format("20060102") + "-" + hex.EncodeToString(suffix)
	pub := key.Public().(ed25519.PublicKey)

	_, err = fmt.Fprintf(w, "JWT_SIGNING_KID=%s\nJWT_SIGNING_KEY=%s\nJWT_VERIFY_KEYS=%s:%s\n",
		kid,
		base64.StdEncoding.EncodeToString(key.Seed()),
		kid, base64.StdEncoding.EncodeToString(pub))
	return err
}
