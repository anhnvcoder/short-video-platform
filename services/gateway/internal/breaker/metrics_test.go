package breaker

import (
	"context"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// readStates makes a meter provider with a manual reader global until the test ends and
// returns a function that collects svp.breaker.state by target. Breakers built after it report
// there.
func readStates(t *testing.T) func() map[string]int64 {
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
		if err := reader.Collect(context.Background(), &data); err != nil {
			t.Fatal(err)
		}
		out := map[string]int64{}
		for _, scope := range data.ScopeMetrics {
			for _, m := range scope.Metrics {
				gauge, ok := m.Data.(metricdata.Gauge[int64])
				if m.Name != "svp.breaker.state" || !ok {
					continue
				}
				if m.Unit != "" {
					t.Errorf("unit = %q, want none", m.Unit)
				}
				for _, p := range gauge.DataPoints {
					target, _ := p.Attributes.Value("target")
					if p.Attributes.Len() != 1 || target.AsString() == "" {
						t.Errorf("labels = %v, want target only", p.Attributes)
					}
					out[target.AsString()] = p.Value
				}
			}
		}
		return out
	}
}

// TestStateGauge: each target reports 0 from the start, 2 once its breaker opens, 1 while the
// trial call runs and 0 again once the breaker closes; other targets are not affected. The open
// state is checked on a breaker that stays open for an hour, so no check races the 50 ms open
// period of the breaker that goes on to half-open: the gauge holds the last change, and that
// breaker's trial starts whenever the test gets to it after the open period.
func TestStateGauge(t *testing.T) {
	collect := readStates(t)
	held := fast
	held.openFor = time.Hour
	fh, heldConn := start(t, newInterceptor(held, "metric-held", nil))
	f, conn := start(t, newInterceptor(fast, "metric-target", nil))
	start(t, newInterceptor(fast, "metric-other", nil))
	got := collect()
	for _, target := range []string{"metric-held", "metric-target", "metric-other"} {
		// Breakers of other tests may report too, under their own targets.
		if v, ok := got[target]; !ok || v != 0 {
			t.Fatalf("states = %v, want %s at 0 before any call", got, target)
		}
	}

	fh.fail(codes.Unavailable)
	callN(t, heldConn, testMethod, 5, codes.Unavailable)
	before := fh.count()
	if err := invoke(t.Context(), heldConn, testMethod); status.Code(err) != codes.Unavailable || fh.count() != before {
		t.Fatalf("call to the open breaker: %v, reached the server %d times; want UNAVAILABLE without reaching it", err, fh.count()-before)
	}
	if got := collect(); got["metric-held"] != 2 || got["metric-other"] != 0 {
		t.Fatalf("states = %v, want metric-held 2 (open), metric-other 0", got)
	}
	// Still open without traffic: the gauge keeps the last change.
	if got := collect(); got["metric-held"] != 2 {
		t.Fatalf("states = %v on the next collection, want metric-held still 2", got)
	}

	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 5, codes.Unavailable)
	if got := collect(); got["metric-target"] != 2 {
		t.Fatalf("states = %v, want metric-target 2 (open)", got)
	}
	time.Sleep(fast.openFor + 10*time.Millisecond)
	trial, release := make(chan struct{}), make(chan struct{})
	f.setAnswer(func(context.Context) error {
		close(trial)
		<-release
		return nil
	})
	done := make(chan error, 1)
	go func() { done <- invoke(t.Context(), conn, testMethod) }()
	<-trial
	if got := collect(); got["metric-target"] != 1 {
		t.Errorf("states = %v during the trial call, want metric-target 1 (half-open)", got)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatalf("trial call: %v", err)
	}
	if got := collect(); got["metric-target"] != 0 {
		t.Errorf("states = %v after the trial succeeded, want metric-target 0 (closed)", got)
	}
}
