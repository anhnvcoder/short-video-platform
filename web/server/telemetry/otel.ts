import "server-only";
import { randomUUID } from "node:crypto";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-grpc";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-grpc";
import { HttpInstrumentation } from "@opentelemetry/instrumentation-http";
import { UndiciInstrumentation } from "@opentelemetry/instrumentation-undici";
import * as api from "@opentelemetry/api";
import * as core from "@opentelemetry/core";
import * as resources from "@opentelemetry/resources";
import * as metrics from "@opentelemetry/sdk-metrics";
import { NodeSDK, type NodeSDKConfiguration } from "@opentelemetry/sdk-node";
import * as tracing from "@opentelemetry/sdk-trace";
import type { Event } from "@sentry/nextjs";
import type { ServerEnv } from "../env";
import { vitals } from "./vitals";

// Traces and metrics of the Next server over OTLP/gRPC to the Collector, as for the Go services (internal/telemetry;
// docs/adr/0019-web-k3d-supply-chain-observability.md, section 10). Logs stay on stdout: no OTLP log exporter.

// W3C TraceContext on the calls the server makes, never read from the requests it receives
// (docs/adr/0019-web-k3d-supply-chain-observability.md, section 7). Nothing in front of the compose web container drops
// a browser's traceparent, so reading it would let any client pick the trace id of the web's spans and, through the
// BFF's calls, of the gateway's. Every request to the web opens a new trace, Next's own span too (Next reads the
// incoming context through this global propagator), and the BFF's calls carry that trace to the gateway. No baggage.
const traceContext = new core.W3CTraceContextPropagator();

export const injectOnlyPropagator: api.TextMapPropagator = {
  inject: (context, carrier, setter) => traceContext.inject(context, carrier, setter),
  extract: (context) => context,
  fields: () => traceContext.fields(),
};

// Requests not worth a trace: probes, static files, and the browser's own telemetry (as the gateway skips its probes).
const unrecordedPaths = new Set(["/healthz", "/favicon.ico", "/monitoring", "/rum"]);

function isUnrecorded(path: string): boolean {
  return unrecordedPaths.has(path) || path.startsWith("/_next/static/");
}

// Decides on root spans by path, before the given sampler: the http instrumentation's server span carries url.path,
// Next's request span (the root when the http module is not patched, see startSdk) carries http.target with the query.
// Every child follows its root (parent-based), so a skipped request records no span at all. Ignoring the requests in
// the http instrumentation alone would not do: Next's span would then become the root of a trace per probe.
export function skipUnrecordedPaths(sampler: tracing.Sampler): tracing.Sampler {
  return {
    shouldSample(context, traceId, spanName, spanKind, attributes, links) {
      const parent = api.trace.getSpanContext(context);
      const path = attributes["url.path"] ?? attributes["http.target"];
      if ((parent === undefined || !api.isSpanContextValid(parent)) && typeof path === "string") {
        if (isUnrecorded(path.split("?")[0] ?? path)) {
          return { decision: tracing.SamplingDecision.NOT_RECORD };
        }
      }
      return sampler.shouldSample(context, traceId, spanName, spanKind, attributes, links);
    },
    toString: () => `SkipUnrecordedPaths{${sampler.toString()}}`,
  };
}

// The query and fragment of every URL or path in a text: `/a?b=c` becomes `/a`, `http://h/a?b#c` becomes `http://h/a`.
// Each word (a run of text between white space) is cut at its first "?" or "#" that comes after a "/"; a word without
// a "/" before its "?" is left alone. One pass, no regular expression: the text comes from the client (a request's
// path, its User-Agent) and this runs twice on every span, so its cost has to stay linear in the length; a
// backtracking URL pattern is quadratic on a long path without a "?" and blocks the event loop.
export function withoutQuery(text: string): string {
  let clean = "";
  // Text before this index is in `clean` already or dropped.
  let kept = 0;
  let inPath = false;
  let queryAt = -1;
  for (let i = 0; i <= text.length; i++) {
    const char = text[i];
    // trim() drops exactly the white space and line terminators that \s matches.
    if (char === undefined || char.trim() === "") {
      if (queryAt >= 0) {
        clean += text.slice(kept, queryAt);
        kept = i;
      }
      inPath = false;
      queryAt = -1;
    } else if (queryAt < 0) {
      if (char === "/") {
        inPath = true;
      } else if (inPath && (char === "?" || char === "#")) {
        queryAt = i;
      }
    }
  }
  return clean + text.slice(kept);
}

function scrubAttributes(attributes: api.Attributes): void {
  delete attributes["url.query"];
  for (const [key, value] of Object.entries(attributes)) {
    if (typeof value === "string") {
      attributes[key] = withoutQuery(value);
    }
  }
}

// No query string in any span (WEB-9): a query may hold a page token, a next= redirect or, on a URL of storage, the
// signature of a presigned request. Next opens its request span with http.target = the raw URL, and its fetch span
// with the full URL in the name and in http.url, outside of what the instrumentations' options reach, so this runs on
// every span: on start, to rename it while that is still allowed, and on end, for attributes set while it ran.
export class ScrubbingSpanProcessor implements tracing.SpanProcessor {
  constructor(private readonly next: tracing.SpanProcessor) {}

  onStart(span: tracing.Span, parentContext: api.Context): void {
    const name = withoutQuery(span.name);
    if (name !== span.name) {
      span.updateName(name);
    }
    scrubAttributes(span.attributes);
    this.next.onStart(span, parentContext);
  }

  onEnd(span: tracing.ReadableSpan): void {
    scrubAttributes(span.attributes);
    this.next.onEnd(span);
  }

  forceFlush(): Promise<void> {
    return this.next.forceFlush();
  }

  shutdown(): Promise<void> {
    return this.next.shutdown();
  }
}

// OTEL_TRACES_SAMPLER and OTEL_TRACES_SAMPLER_ARG as the Go services read them: parentbased_always_on when unset, and
// for a name the specification does not know; a ratio outside [0, 1] or missing counts as 1. NodeSDK reads these only
// when it is given no sampler, and the sampler of telemetryConfig wraps this one, so it reads them itself.
export function samplerFromEnv(): tracing.Sampler {
  const ratio = () => {
    const arg = core.getNumberFromEnv("OTEL_TRACES_SAMPLER_ARG");
    if (arg === undefined || arg < 0 || arg > 1) {
      api.diag.error(`OTEL_TRACES_SAMPLER_ARG is ${arg ?? "blank"}, not a ratio in [0, 1]: using 1`);
      return 1;
    }
    return arg;
  };
  const name = core.getStringFromEnv("OTEL_TRACES_SAMPLER");
  switch (name) {
    case "always_on":
      return new tracing.AlwaysOnSampler();
    case "always_off":
      return new tracing.AlwaysOffSampler();
    case "parentbased_always_off":
      return new tracing.ParentBasedSampler({ root: new tracing.AlwaysOffSampler() });
    case "traceidratio":
      return new tracing.TraceIdRatioBasedSampler(ratio());
    case "parentbased_traceidratio":
      return new tracing.ParentBasedSampler({ root: new tracing.TraceIdRatioBasedSampler(ratio()) });
    case undefined:
    case "parentbased_always_on":
      return new tracing.ParentBasedSampler({ root: new tracing.AlwaysOnSampler() });
    default:
      api.diag.error(`unknown OTEL_TRACES_SAMPLER value "${name}": using parentbased_always_on`);
      return new tracing.ParentBasedSampler({ root: new tracing.AlwaysOnSampler() });
  }
}

// The batch processor of the OTLP exporter, with the OTEL_BSP_* variables read as the BatchSpanProcessor of
// sdk-trace-base read them: any number, 0 included (OTEL_BSP_SCHEDULE_DELAY=0 sends each batch at once); unset, blank
// or not a number leaves the default. BatchSpanProcessor no longer reads them itself; NodeSDK reads them only for a
// processor it makes from a traceExporter, which would sit outside ScrubbingSpanProcessor.
export function batchSpanProcessorFromEnv(exporter: tracing.SpanExporter): tracing.SpanProcessor {
  return new tracing.BatchSpanProcessor({
    exporter,
    maxQueueSize: core.getNumberFromEnv("OTEL_BSP_MAX_QUEUE_SIZE"),
    scheduledDelayMillis: core.getNumberFromEnv("OTEL_BSP_SCHEDULE_DELAY"),
    exportTimeoutMillis: core.getNumberFromEnv("OTEL_BSP_EXPORT_TIMEOUT"),
    maxExportBatchSize: core.getNumberFromEnv("OTEL_BSP_MAX_EXPORT_BATCH_SIZE"),
  });
}

// Explicit buckets of the web vital histograms (server/telemetry/vitals.ts).
export const vitalViews: metrics.ViewOptions[] = Object.values(vitals).map(({ instrument, buckets }) => ({
  instrumentName: instrument,
  aggregation: { type: metrics.AggregationType.EXPLICIT_BUCKET_HISTOGRAM, options: { boundaries: [...buckets] } },
}));

// Incoming requests (http) and the BFF's fetch calls to the gateway (undici, the fetch of Node), which is also where
// traceparent is written. Request and response headers are never recorded (no headersToSpanAttributes). Outgoing calls
// are traced only inside a request: the error reports the Sentry SDK sends on its own would otherwise each start a
// trace.
export function instrumentations() {
  return [
    new HttpInstrumentation({ requireParentforOutgoingSpans: true }),
    new UndiciInstrumentation({ requireParentforSpans: true }),
  ];
}

// Where spans and metrics go: the OTLP exporters, or a test's in-memory ones.
export interface TelemetryExport {
  spans: tracing.SpanProcessor;
  metrics: metrics.IMetricReader;
}

type TelemetryConfig = Partial<NodeSDKConfiguration> & Pick<NodeSDKConfiguration, "instrumentations">;

// The SDK's configuration; nothing is recorded or sent when `exports` is null.
export function telemetryConfig(env: ServerEnv, exports: TelemetryExport | null): TelemetryConfig {
  return {
    // Only these attributes, as the Go services: no host, process or OTEL_RESOURCE_ATTRIBUTES detection.
    autoDetectResources: false,
    resource: resources.resourceFromAttributes({
      "service.name": "web",
      "service.instance.id": randomUUID(),
      ...(env.buildId !== undefined && { "service.version": env.buildId }),
    }),
    textMapPropagator: injectOnlyPropagator,
    // OTEL_TRACES_SAMPLER as for the Go services, parentbased_always_on when unset.
    sampler: skipUnrecordedPaths(samplerFromEnv()),
    spanProcessors: exports ? [new ScrubbingSpanProcessor(exports.spans)] : [],
    metricReaders: exports ? [exports.metrics] : [],
    views: vitalViews,
    // An empty list, not none: without it the SDK sets up an OTLP log exporter from the environment.
    logRecordProcessors: [],
    instrumentations: instrumentations(),
  };
}

// Starts the SDK with this configuration, and patches the http module that is already loaded. The http
// instrumentation patches http when it is required after the SDK started, but that never happens in the server: Next's
// start-server.js requires http before register() runs, and the bundle requires each built-in module once and keeps
// it, so no require after the SDK started reaches the instrumentation's hook. Without the patch the web has no server
// span of its own and no http.server.request.duration, the histogram of its availability SLO. Loading http once more
// through the hook the instrumentation installed patches the module in place, including http.Server.prototype.emit,
// which the server Next has already created looks up on every request. process.getBuiltinModule, not require: the
// bundler would turn a require into its cached copy of the module, which never reaches the hook.
export function startSdk(config: TelemetryConfig): NodeSDK {
  const sdk = new NodeSDK(config);
  sdk.start();
  process.getBuiltinModule("node:http");
  return sdk;
}

// Starts the SDK unless OTEL_SDK_DISABLED is true. Exporters exist only with an explicit OTEL_EXPORTER_OTLP_ENDPOINT
// (the SDK would otherwise send to localhost:4317); without one nothing is recorded or sent. A Collector that cannot
// be reached costs nothing but dropped telemetry: exports run in the background and their errors are discarded.
export function startTelemetry(env: ServerEnv): NodeSDK | null {
  if (core.getBooleanFromEnv("OTEL_SDK_DISABLED")) {
    return null;
  }
  const otlp = core.getStringFromEnv("OTEL_EXPORTER_OTLP_ENDPOINT") !== undefined;
  return startSdk(
    telemetryConfig(
      env,
      otlp
        ? {
            spans: batchSpanProcessorFromEnv(new OTLPTraceExporter()),
            // Every 15 s like the Go services (the JS SDK's default is 60 s).
            metrics: new metrics.PeriodicExportingMetricReader({
              exporter: new OTLPMetricExporter(),
              exportIntervalMillis: 15_000,
            }),
          }
        : null,
    ),
  );
}

// Event processor of the error tracker: a server error carries the trace and span ids of the span it happened in, to
// find the same request in Tempo, as the Go services' errors do. Browser reports and errors outside a recorded span
// (a skipped path, telemetry off) get none: their ids would lead to no trace.
export function addTraceTags(event: Event): Event {
  const span = api.trace.getActiveSpan();
  if (event.tags?.runtime === "browser" || span === undefined || !span.isRecording()) {
    return event;
  }
  const { traceId, spanId } = span.spanContext();
  return { ...event, tags: { ...event.tags, trace_id: traceId, span_id: spanId } };
}
