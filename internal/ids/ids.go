// Package ids creates and checks the UUIDv7 ids of the platform's entities
// (docs/adr/0006-contract-ids-and-event-envelope.md, section 2).
package ids

import (
	"errors"
	"uuid"
)

// ErrInvalid is returned by Parse for anything but a canonical UUID.
var ErrInvalid = errors.New("ids: not a canonical lowercase UUID")

// New returns a new UUIDv7 in canonical form (36 lowercase characters with hyphens).
func New() string {
	return uuid.NewV7().String()
}

// Parse returns the UUID in s. Only the canonical form is accepted: uuid.Parse also takes
// upper case, braces, a urn:uuid: prefix and no hyphens, and letting several spellings of the
// same id through would make string comparisons, cache keys and logs disagree.
func Parse(s string) (uuid.UUID, error) {
	u, err := uuid.Parse(s)
	if err != nil || u.String() != s {
		return uuid.UUID{}, ErrInvalid
	}
	return u, nil
}
