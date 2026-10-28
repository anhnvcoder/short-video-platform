package httpx

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// maxBodyBytes caps a JSON request body (threat model RL-4); files never go through the gateway.
const maxBodyBytes = 64 << 10

// DecodeJSON decodes the request body, one JSON object of at most 64 KiB, into dst. Unknown
// fields, null values and anything after the object are rejected. On failure it writes the
// problem response (413 when the body is too large, 400 otherwise) and returns false; the handler
// then returns.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	var raw json.RawMessage
	err := dec.Decode(&raw)
	if err == nil {
		if extra := dec.Decode(&struct{}{}); !errors.Is(extra, io.EOF) {
			err = errors.New("unexpected data after the JSON object")
			if tooLarge(extra) {
				err = extra
			}
		}
	}
	if err == nil {
		err = decodeObject(raw, dst)
	}
	switch {
	case err == nil:
		return true
	case tooLarge(err):
		WriteProblem(w, r, http.StatusRequestEntityTooLarge, "BODY_TOO_LARGE", "request body exceeds 64 KiB")
	case errors.Is(err, io.EOF):
		WriteProblem(w, r, http.StatusBadRequest, "INVALID_JSON", "request body is empty")
	default:
		WriteProblem(w, r, http.StatusBadRequest, "INVALID_JSON", "invalid JSON body: "+err.Error())
	}
	return false
}

// decodeObject decodes raw, one complete JSON value, into dst. encoding/json skips a null, both
// for a field (which keeps its zero value, as if absent) and for the whole body (dst stays
// empty), so a request the API documents as invalid would reach the handler: each is refused
// here first. Request bodies are flat objects, so only their top-level values are checked.
func decodeObject(raw json.RawMessage, dst any) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || fields == nil {
		return errors.New("the body must be one JSON object")
	}
	for name, value := range fields {
		if string(value) == "null" {
			return fmt.Errorf("field %q is null", name)
		}
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}

func tooLarge(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}
