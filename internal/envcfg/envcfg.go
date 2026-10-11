// Package envcfg reads service configuration from environment variables.
//
// An empty variable counts as unset, so `VAR=` in a compose file behaves like a missing VAR.
package envcfg

import (
	"fmt"
	"os"
)

// String returns the value of the variable name, or def when it is unset or empty.
func String(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

// Required returns the value of the variable name. The error names the variable and never
// carries a value, since required variables are often secrets.
func Required(name string) (string, error) {
	v := os.Getenv(name)
	if v == "" {
		return "", fmt.Errorf("required environment variable %s is not set", name)
	}
	return v, nil
}
