package envcfg

import (
	"strings"
	"testing"
)

const testVar = "SVP_ENVCFG_TEST_VAR"

func TestString(t *testing.T) {
	tests := []struct {
		name  string
		value string
		want  string
	}{
		{name: "set", value: "127.0.0.1:9999", want: "127.0.0.1:9999"},
		{name: "empty uses default", value: "", want: "127.0.0.1:9101"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(testVar, tt.value)
			if got := String(testVar, "127.0.0.1:9101"); got != tt.want {
				t.Errorf("String() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestRequiredSet(t *testing.T) {
	t.Setenv(testVar, "secret-value")
	got, err := Required(testVar)
	if err != nil {
		t.Fatalf("Required() error = %v", err)
	}
	if got != "secret-value" {
		t.Errorf("Required() = %q, want %q", got, "secret-value")
	}
}

func TestRequiredMissingNamesVariable(t *testing.T) {
	t.Setenv(testVar, "")
	_, err := Required(testVar)
	if err == nil {
		t.Fatal("Required() error = nil, want an error for an empty variable")
	}
	if !strings.Contains(err.Error(), testVar) {
		t.Errorf("error %q does not name the variable %s", err, testVar)
	}
}
