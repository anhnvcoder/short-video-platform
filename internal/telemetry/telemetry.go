// Package telemetry configures the process-wide OpenTelemetry providers and optional profiler.
// Services call Setup once, only from their serve command, before starting work.
package telemetry

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
)

const (
	exportTimeout = 5 * time.Second
	queueSize     = 2048
)

// Setup installs providers and W3C TraceContext propagation. Exporters are created only with
// an explicit OTEL_EXPORTER_OTLP_ENDPOINT; their connections are lazy and never block startup.
// Shutdown flushes all signals and stops profiling under a single five-second budget.
func Setup(ctx context.Context, service string) (shutdown func(context.Context) error, err error) {
	if disabled, _ := strconv.ParseBool(os.Getenv("OTEL_SDK_DISABLED")); disabled {
		return func(context.Context) error { return nil }, nil
	}
	otel.SetErrorHandler(newErrorHandler(time.Now))
	res := resource.NewWithAttributes(semconv.SchemaURL,
		semconv.ServiceName(service), semconv.ServiceInstanceID(rand.Text()))
	var stops []func(context.Context) error
	defer func() {
		if err != nil {
			_ = stopAll(context.WithoutCancel(ctx), stops)
		}
	}()

	var traceExporter sdktrace.SpanExporter
	var reader sdkmetric.Reader
	var logExporter sdklog.Exporter
	// Guard all three exporters: SDK defaults would otherwise dial localhost:4317.
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != "" {
		traceExporter, err = otlptracegrpc.New(ctx, otlptracegrpc.WithTimeout(exportTimeout))
		if err != nil {
			return nil, fmt.Errorf("create trace exporter: %w", err)
		}
		stops = append(stops, traceExporter.Shutdown)
		metricExporter, e := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithTimeout(exportTimeout))
		if e != nil {
			return nil, fmt.Errorf("create metric exporter: %w", e)
		}
		reader = sdkmetric.NewPeriodicReader(metricExporter,
			sdkmetric.WithInterval(15*time.Second), sdkmetric.WithTimeout(exportTimeout))
		stops = append(stops, reader.Shutdown)
		logExporter, err = otlploggrpc.New(ctx, otlploggrpc.WithTimeout(exportTimeout))
		if err != nil {
			return nil, fmt.Errorf("create log exporter: %w", err)
		}
		stops = append(stops, logExporter.Shutdown)
	}
	tp := newTracerProvider(res, traceExporter)
	mp := newMeterProvider(res, reader)
	lp := newLoggerProvider(res, logExporter)
	stops = []func(context.Context) error{tp.Shutdown, mp.Shutdown, lp.Shutdown}
	if err = runtime.Start(runtime.WithMeterProvider(mp)); err != nil {
		return nil, fmt.Errorf("start runtime metrics: %w", err)
	}
	if address := os.Getenv("PYROSCOPE_SERVER_ADDRESS"); address != "" {
		stop, e := startProfiler(service, address)
		if e != nil {
			return nil, fmt.Errorf("start profiler: %w", e)
		}
		stops = append(stops, stop)
	}
	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetLoggerProvider(lp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	var once sync.Once
	var shutdownErr error
	return func(ctx context.Context) error {
		once.Do(func() { shutdownErr = stopAll(ctx, stops) })
		return shutdownErr
	}, nil
}

func newTracerProvider(res *resource.Resource, exporter sdktrace.SpanExporter) *sdktrace.TracerProvider {
	opts := []sdktrace.TracerProviderOption{sdktrace.WithResource(res)}
	if exporter != nil {
		opts = append(opts, sdktrace.WithBatcher(exporter,
			sdktrace.WithMaxQueueSize(queueSize), sdktrace.WithExportTimeout(exportTimeout)))
	}
	// The SDK reads OTEL_TRACES_SAMPLER/ARG and defaults to parentbased_always_on.
	return sdktrace.NewTracerProvider(opts...)
}

func newLoggerProvider(res *resource.Resource, exporter sdklog.Exporter) *sdklog.LoggerProvider {
	opts := []sdklog.LoggerProviderOption{sdklog.WithResource(res)}
	if exporter != nil {
		opts = append(opts, sdklog.WithProcessor(sdklog.NewBatchProcessor(exporter,
			sdklog.WithMaxQueueSize(queueSize), sdklog.WithExportTimeout(exportTimeout))))
	}
	return sdklog.NewLoggerProvider(opts...)
}

func newMeterProvider(res *resource.Resource, reader sdkmetric.Reader) *sdkmetric.MeterProvider {
	opts := []sdkmetric.Option{sdkmetric.WithResource(res)}
	for _, name := range []string{"http.server.request.duration", "rpc.server.call.duration", "rpc.client.call.duration"} {
		opts = append(opts, sdkmetric.WithView(sdkmetric.NewView(
			sdkmetric.Instrument{Name: name, Kind: sdkmetric.InstrumentKindHistogram, Unit: "s"},
			sdkmetric.Stream{Aggregation: sdkmetric.AggregationExplicitBucketHistogram{
				Boundaries: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1, 2.5, 5, 10},
			}},
		)))
	}
	if reader != nil {
		opts = append(opts, sdkmetric.WithReader(reader))
	}
	return sdkmetric.NewMeterProvider(opts...)
}

func stopAll(ctx context.Context, stops []func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, exportTimeout)
	defer cancel()
	results := make(chan error, len(stops))
	for _, stop := range stops {
		go func() { results <- stop(ctx) }()
	}
	var err error
	for range stops {
		select {
		case e := <-results:
			err = errors.Join(err, e)
		case <-ctx.Done():
			return errors.Join(err, ctx.Err())
		}
	}
	return err
}
