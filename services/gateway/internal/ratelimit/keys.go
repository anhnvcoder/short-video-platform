package ratelimit

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/netip"
	"strings"

	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
)

// ClientIP is the id of the client's address for the IP classes: the address that from, the
// one ClientAddr the whole gateway asks, finds for r. Its zero value takes the connection's address
// (r.RemoteAddr) and ignores X-Forwarded-For, X-Real-IP, Forwarded and every other header the
// client sets, since a client could put any address in them (threat model RL-1). An IPv6
// address counts as its /64, which a subscriber usually holds whole.
func ClientIP(r *http.Request, from httpx.ClientAddr) string {
	host := from.Of(r)
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	addr = addr.Unmap()
	if addr.Is4() {
		return addr.String()
	}
	p, _ := addr.Prefix(64) // never fails for a 128-bit address
	return p.String()
}

// LoginEmailID is the id of (ip, email) for LoginEmail. The email is normalized like
// user-service does (TrimSpace, ToLower) and hashed, so no raw email lands in Redis (threat
// model JWT-8): the first 32 hex characters of its SHA-256.
func LoginEmailID(ip, email string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(email))))
	return ip + ":" + hex.EncodeToString(sum[:])[:32]
}
