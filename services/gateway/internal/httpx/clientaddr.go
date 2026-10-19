package httpx

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// ClientAddr finds the client's address of a request. Every part of the gateway that needs it
// (the rate limits by IP, the client.address of spans) asks the same ClientAddr, so they never
// disagree on who the client is.
//
// X-Forwarded-For is a header the client writes too: anything a client puts there arrives
// first, and each proxy appends the address it received the request from. Only the elements
// appended by proxies the gateway runs behind are true, so the gateway must know how many
// there are (hops) and take the element the farthest of them appended: the hops-th from the
// right. Counting too few hops puts every client into one bucket, the address of the proxy in
// front; counting too many reads an element the client wrote, so a client gets a new IP on every
// request and slips past every limit by IP (threat model RL-1).
//
// The zero value trusts no proxy and takes the connection's address, ignoring every header: the
// safe choice when nothing is in front of the gateway (compose), since there any header comes
// straight from the client. X-Real-IP and Forwarded are never read.
type ClientAddr struct {
	hops    int
	trusted []netip.Prefix
}

// NewClientAddr returns a ClientAddr that reads X-Forwarded-For only on connections from an
// address in trusted, and takes the hops-th element from the right. hops 0 trusts no proxy.
func NewClientAddr(hops int, trusted []netip.Prefix) ClientAddr {
	return ClientAddr{hops: hops, trusted: trusted}
}

// Of returns the client's address of r: an IP address, or the connection's host as it is when
// that does not parse. It falls back to the connection's address whenever X-Forwarded-For cannot
// be trusted: the connection does not come from a trusted proxy (a client reaching the gateway
// directly), the list has fewer than hops elements, or the chosen element is not a bare IP
// address (a port or a name in it). Falling back puts such requests into the bucket of the
// connection, which is never an address the client chose.
func (c ClientAddr) Of(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if c.hops == 0 {
		return host
	}
	conn, err := netip.ParseAddr(host)
	if err != nil || !c.fromTrustedProxy(conn.Unmap()) {
		return host
	}
	// Several X-Forwarded-For headers make one list, in the order they arrive (RFC 9110 section
	// 5.3); the element a proxy appended may sit in the last header or in a header of its own.
	elems := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
	if len(elems) < c.hops {
		return host
	}
	addr, err := netip.ParseAddr(strings.TrimSpace(elems[len(elems)-c.hops]))
	if err != nil {
		return host
	}
	return addr.Unmap().String()
}

// fromTrustedProxy reports whether conn, the connection's address, lies in a trusted range.
func (c ClientAddr) fromTrustedProxy(conn netip.Addr) bool {
	for _, p := range c.trusted {
		if p.Contains(conn) {
			return true
		}
	}
	return false
}
