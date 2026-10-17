package sentryx

import (
	"encoding/json"
	"regexp"

	"github.com/getsentry/sentry-go"
)

var (
	emailPattern = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`)
	jwtPattern   = regexp.MustCompile(`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)
)

func redact(s string) string {
	return jwtPattern.ReplaceAllString(emailPattern.ReplaceAllString(s, "[redacted]"), "[redacted]")
}

func beforeSend(event *sentry.Event, _ *sentry.EventHint) *sentry.Event {
	event.Request = nil
	event.User = sentry.User{ID: redact(event.User.ID)}
	event.Message = redact(event.Message)
	// The SDK otherwise supplies the machine hostname even with PII disabled.
	event.ServerName = ""
	for i := range event.Exception {
		event.Exception[i].Type = redact(event.Exception[i].Type)
		event.Exception[i].Value = redact(event.Exception[i].Value)
	}
	cleanTags := make(map[string]string, len(event.Tags))
	for key, value := range event.Tags {
		cleanTags[redact(key)] = redact(value)
	}
	event.Tags = cleanTags
	cleanContexts := make(map[string]sentry.Context, len(event.Contexts))
	for key, value := range event.Contexts {
		cleanContexts[redact(key)] = cleanMap(value)
	}
	event.Contexts = cleanContexts
	for _, breadcrumb := range event.Breadcrumbs {
		if breadcrumb == nil {
			continue
		}
		breadcrumb.Message = redact(breadcrumb.Message)
		breadcrumb.Type = redact(breadcrumb.Type)
		breadcrumb.Category = redact(breadcrumb.Category)
		breadcrumb.Level = sentry.Level(redact(string(breadcrumb.Level)))
		breadcrumb.Data = cleanMap(breadcrumb.Data)
	}
	for i, value := range event.Fingerprint {
		event.Fingerprint[i] = redact(value)
	}
	return event
}

// Normalize nested maps, slices, structs and JSON values before walking them.
// sentry-go v0.50 moved extra data into contexts; no Event.Extra remains.
func cleanMap(value map[string]any) map[string]any {
	data, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil
	}
	clean, _ := cleanValue(decoded).(map[string]any)
	return clean
}

func cleanValue(value any) any {
	switch value := value.(type) {
	case string:
		return redact(value)
	case map[string]any:
		clean := make(map[string]any, len(value))
		for key, child := range value {
			clean[redact(key)] = cleanValue(child)
		}
		return clean
	case []any:
		for i, child := range value {
			value[i] = cleanValue(child)
		}
	}
	return value
}
