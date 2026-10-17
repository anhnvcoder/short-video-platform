package ratelimit

import (
	"context"
	"fmt"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

// readDecisions makes a meter provider with a manual reader global until the test ends and
// returns a function that collects svp.ratelimit.decisions as "class result store" → value.
// Limiters built after it record there.
func readDecisions(t *testing.T) func() map[string]int64 {
	t.Helper()
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})
	return func() map[string]int64 {
		t.Helper()
		var data metricdata.ResourceMetrics
		if err := reader.Collect(t.Context(), &data); err != nil {
			t.Fatal(err)
		}
		out := map[string]int64{}
		for _, scope := range data.ScopeMetrics {
			for _, m := range scope.Metrics {
				sum, ok := m.Data.(metricdata.Sum[int64])
				if m.Name != "svp.ratelimit.decisions" || !ok {
					continue
				}
				if !sum.IsMonotonic || m.Unit != "" {
					t.Errorf("decisions: monotonic %v, unit %q; want a counter without unit", sum.IsMonotonic, m.Unit)
				}
				for _, p := range sum.DataPoints {
					if p.Attributes.Len() != 3 {
						t.Errorf("decisions labels = %v, want class, result, store", p.Attributes)
					}
					class, _ := p.Attributes.Value("class")
					result, _ := p.Attributes.Value("result")
					store, _ := p.Attributes.Value("store")
					out[fmt.Sprintf("%s %s %s", class.AsString(), result.AsString(), store.AsString())] = p.Value
				}
			}
		}
		return out
	}
}

// TestDecisionSeriesStartAtZero: every series of the configured classes exists, at 0, before
// the first request.
func TestDecisionSeriesStartAtZero(t *testing.T) {
	collect := readDecisions(t)
	New(downClient(t), "svp:test:down:")
	got := collect()
	if len(got) != len(classes)*4 {
		t.Errorf("series = %d, want %d: %v", len(got), len(classes)*4, got)
	}
	for _, c := range classes {
		for _, series := range []string{"allowed redis", "limited redis", "allowed fallback", "limited fallback"} {
			key := c.Name + " " + series
			if v, ok := got[key]; !ok || v != 0 {
				t.Errorf("%s = %d (present %v), want 0", key, v, ok)
			}
		}
	}
}

// TestDecisionsWhileRedisDown is threat model RL-2: decisions made without Redis are counted
// under store="fallback", for a soft-closed class (allowed and limited) and an open one.
func TestDecisionsWhileRedisDown(t *testing.T) {
	captureLog(t)
	collect := readDecisions(t)
	l := New(downClient(t), "svp:test:down:")
	// A clock that does not move, so no request refills the bucket however slow the run.
	l.mem = newMemory(newFakeClock().Now)
	soft := Class{Name: "metric-soft", Limit: Limit{100, time.Second, 100}, Fallback: testLimit}
	for range testLimit.Burst + 1 {
		l.Allow(t.Context(), soft, "id")
	}
	open := Class{Name: "metric-open", Limit: testLimit}
	l.Allow(t.Context(), open, "id")

	got := collect()
	want := map[string]int64{
		"metric-soft allowed fallback": int64(testLimit.Burst),
		"metric-soft limited fallback": 1,
		"metric-open allowed fallback": 1,
	}
	for key, v := range want {
		if got[key] != v {
			t.Errorf("%s = %d, want %d", key, got[key], v)
		}
	}
	for key, v := range got {
		if _, ok := want[key]; !ok && v != 0 {
			t.Errorf("%s = %d, want 0", key, v)
		}
	}
}

// hourLimit refills one request every 20 minutes: no test run is slow enough to see a refill.
var hourLimit = Limit{Rate: 3, Period: time.Hour, Burst: 3}

func TestDecisionsOnRedis(t *testing.T) {
	client, prefix := testRedis(t)
	collect := readDecisions(t)
	l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
	c := Class{Name: "metric-redis", Limit: hourLimit}
	for range hourLimit.Burst + 1 {
		l.Allow(t.Context(), c, "id")
	}
	got := collect()
	if got["metric-redis allowed redis"] != int64(hourLimit.Burst) || got["metric-redis limited redis"] != 1 ||
		got["metric-redis allowed fallback"] != 0 || got["metric-redis limited fallback"] != 0 {
		t.Errorf("decisions = %v, want %d allowed and 1 limited on redis", got, hourLimit.Burst)
	}
}

// TestDecisionsOfCancelledRequestsNotCounted: with Redis up, a request whose context is already
// cancelled (the client went away) fails its Redis call but is not counted under fallback, so
// it cannot look like Redis failing (threat model RL-2).
func TestDecisionsOfCancelledRequestsNotCounted(t *testing.T) {
	logs := captureLog(t)
	client, prefix := testRedis(t)
	collect := readDecisions(t)
	l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	soft := Class{Name: "metric-gone-soft", Limit: hourLimit, Fallback: hourLimit}
	open := Class{Name: "metric-gone-open", Limit: hourLimit}
	if ok, _ := l.Allow(ctx, soft, "id"); !ok {
		t.Error("soft-closed class refused the first request")
	}
	if ok, _ := l.Allow(ctx, open, "id"); !ok {
		t.Error("open class refused the request")
	}
	for key, v := range collect() {
		if v != 0 {
			t.Errorf("%s = %d, want 0", key, v)
		}
	}
	if logs.Len() != 0 {
		t.Errorf("logged %s, want nothing", logs)
	}
}
