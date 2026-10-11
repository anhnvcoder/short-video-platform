package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

// maxBodyBytes caps a JSON request body (threat model RL-4); files never go through the gateway.
const maxBodyBytes = 64 << 10

// DecodeJSON decodes the request body, one JSON object of at most 64 KiB, into dst. Unknown
// fields and anything after the object are rejected. On failure it writes the problem response
// (413 when the body is too large, 400 otherwise) and returns false; the handler then returns.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	dec.DisallowUnknownFields()
	err := dec.Decode(dst)
	if err == nil {
		if extra := dec.Decode(&struct{}{}); !errors.Is(extra, io.EOF) {
			err = errors.New("unexpected data after the JSON object")
			if tooLarge(extra) {
				err = extra
			}
		}
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

func tooLarge(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}
