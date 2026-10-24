import * as api from "@opentelemetry/api";
import * as metrics from "@opentelemetry/sdk-metrics";
import { NodeSDK } from "@opentelemetry/sdk-node";
import * as tracing from "@opentelemetry/sdk-trace";
import { http, HttpResponse } from "msw";
import { afterEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { gatewayClient } from "../gateway";
import { fakeAccessToken, gatewayOrigin, testEnv } from "../testing/bff";
import {
  addTraceTags,
  batchSpanProcessorFromEnv,
  injectOnlyPropagator,
  samplerFromEnv,
  ScrubbingSpanProcessor,
  skipUnrecordedPaths,
  telemetryConfig,
  withoutQuery,
} from "./otel";

// The SDK as the server sets it up (telemetryConfig), with spans kept in memory instead of sent to a Collector.
let running: { sdk: NodeSDK; config: ReturnType<typeof telemetryConfig> } | undefined;

function startInMemory() {
  const exporter = new tracing.InMemorySpanExporter();
  const config = telemetryConfig(
    { ...testEnv, buildId: "0123456789ab" },
    {
      spans: new tracing.SimpleSpanProcessor({ exporter }),
      metrics: new metrics.PeriodicExportingMetricReader({ exporter: new metrics.InMemoryMetricExporter(0) }),
    },
  );
  const sdk = new NodeSDK(config);
  sdk.start();
  running = { sdk, config };
  return { exporter, tracer: api.trace.getTracer("test") };
}

afterEach(async () => {
  if (running) {
    // The instrumentations stay hooked into Node until disabled; the SDK's globals stay set until disabled.
    for (const instrumentation of running.config.instrumentations.flat()) {
      instrumentation.disable();
    }
    await running.sdk.shutdown();
    running = undefined;
  }
  api.trace.disable();
  api.context.disable();
  api.propagation.disable();
  api.metrics.disable();
});

const incomingTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

describe("propagation", () => {
  it("reads no trace context from a request: a request with a valid traceparent opens a new root span", () => {
    const { exporter, tracer } = startInMemory();
    // What Next does with the headers of a request it receives, before it opens its request span.
    const context = api.propagation.extract(api.context.active(), {
      traceparent: incomingTraceparent,
      tracestate: "a=b",
    });
    expect(api.trace.getSpanContext(context)).toBeUndefined();

    tracer.startSpan("GET", { kind: api.SpanKind.SERVER }, context).end();
    const [span] = exporter.getFinishedSpans();
    expect(span!.parentSpanContext).toBeUndefined();
    expect(span!.spanContext().traceId).not.toBe("4bf92f3577b34da6a3ce929d0e0e4736");
  });

  it("writes the traceparent of the current span, and nothing else", () => {
    const { tracer } = startInMemory();
    tracer.startActiveSpan("GET", (span) => {
      const carrier: Record<string, string> = {};
      api.propagation.inject(api.context.active(), carrier);
      const { traceId, spanId } = span.spanContext();
      expect(carrier).toEqual({ traceparent: `00-${traceId}-${spanId}-01` });
      span.end();
    });
    expect(injectOnlyPropagator.fields()).toEqual(["traceparent", "tracestate"]);
  });
});

describe("BFF calls to the gateway", () => {
  it("carry the traceparent of the request's trace, recorded without headers, token or query", async () => {
    const { exporter, tracer } = startInMemory();
    const received: Headers[] = [];
    server.use(
      http.get(`${gatewayOrigin}/feed/explore`, ({ request }) => {
        received.push(request.headers);
        return HttpResponse.json({ items: [], next_cursor: "" });
      }),
    );
    const token = fakeAccessToken("6f1a2b3c-4d5e-4f60-8a1b-2c3d4e5f6a7b");

    const traceId = await tracer.startActiveSpan("GET /", { kind: api.SpanKind.SERVER }, async (span) => {
      await gatewayClient(gatewayOrigin, token, "203.0.113.7").GET("/feed/explore", {
        params: { query: { cursor: "secret-cursor" } },
      });
      span.end();
      return span.spanContext().traceId;
    });

    expect(received).toHaveLength(1);
    const traceparent = received[0]!.get("traceparent");
    expect(traceparent).toMatch(new RegExp(`^00-${traceId}-[0-9a-f]{16}-01$`));
    expect(received[0]!.get("baggage")).toBeNull();

    const spans = exporter.getFinishedSpans();
    const client = spans.find((span) => span.kind === api.SpanKind.CLIENT);
    expect(client).toBeDefined();
    // The gateway's span becomes a child of the BFF's client span.
    expect(traceparent).toBe(`00-${traceId}-${client!.spanContext().spanId}-01`);
    expect(client!.attributes["url.full"]).toBe(`${gatewayOrigin}/feed/explore`);
    for (const span of spans) {
      const text = JSON.stringify({ name: span.name, attributes: span.attributes });
      expect(text).not.toContain("secret-cursor");
      expect(text).not.toContain(token);
      expect(text).not.toContain("203.0.113.7");
      expect(Object.keys(span.attributes).filter((key) => key.includes("header"))).toEqual([]);
      expect(span.attributes["url.query"]).toBeUndefined();
    }
  });
});

describe("sampler", () => {
  const inner = new tracing.AlwaysOnSampler();
  const sampler = skipUnrecordedPaths(inner);
  const decide = (attributes: api.Attributes, context = api.ROOT_CONTEXT) =>
    sampler.shouldSample(context, "4bf92f3577b34da6a3ce929d0e0e4736", "GET", api.SpanKind.SERVER, attributes, [])
      .decision;

  it.each(["/healthz", "/_next/static/chunks/a.js", "/favicon.ico", "/monitoring", "/rum"])(
    "records no span for %s, from the http instrumentation's url.path or Next's http.target",
    (path) => {
      expect(decide({ "url.path": path })).toBe(tracing.SamplingDecision.NOT_RECORD);
      expect(decide({ "http.target": `${path}?dpl=dev-1` })).toBe(tracing.SamplingDecision.NOT_RECORD);
      expect(decide({ "http.target": path })).toBe(tracing.SamplingDecision.NOT_RECORD);
    },
  );

  it.each(["/", "/login", "/api/feed/explore", "/healthz/x", "/rumble", "/_next/data/x.json"])(
    "leaves %s to the configured sampler",
    (path) => {
      expect(decide({ "url.path": path })).toBe(tracing.SamplingDecision.RECORD_AND_SAMPLED);
      expect(decide({ "http.target": `${path}?a=1` })).toBe(tracing.SamplingDecision.RECORD_AND_SAMPLED);
    },
  );

  it("leaves a span with a parent to the configured sampler, whatever its attributes", () => {
    const parent = api.trace.setSpanContext(api.ROOT_CONTEXT, {
      traceId: "4bf92f3577b34da6a3ce929d0e0e4736",
      spanId: "00f067aa0ba902b7",
      traceFlags: api.TraceFlags.SAMPLED,
    });
    expect(decide({ "url.path": "/healthz" }, parent)).toBe(tracing.SamplingDecision.RECORD_AND_SAMPLED);
  });

  it("drops every span of a skipped request, Next's and the BFF's under it too", () => {
    const { exporter, tracer } = startInMemory();
    tracer.startActiveSpan("GET", { kind: api.SpanKind.SERVER, attributes: { "http.target": "/rum" } }, (root) => {
      tracer.startSpan("fetch").end();
      root.end();
    });
    tracer.startActiveSpan("GET", { kind: api.SpanKind.SERVER, attributes: { "url.path": "/" } }, (root) => root.end());
    expect(
      exporter.getFinishedSpans().map((span) => span.attributes["url.path"] ?? span.attributes["http.target"]),
    ).toEqual(["/"]);
  });
});

describe("sampler from the environment", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  const parentBased = (root: string) =>
    `ParentBased{root=${root}, remoteParentSampled=AlwaysOnSampler, remoteParentNotSampled=AlwaysOffSampler, ` +
    "localParentSampled=AlwaysOnSampler, localParentNotSampled=AlwaysOffSampler}";

  it.each([
    ["", "", parentBased("AlwaysOnSampler")],
    ["parentbased_always_on", "", parentBased("AlwaysOnSampler")],
    ["always_on", "", "AlwaysOnSampler"],
    ["always_off", "", "AlwaysOffSampler"],
    ["parentbased_always_off", "", parentBased("AlwaysOffSampler")],
    ["traceidratio", "0.25", "TraceIdRatioBased{0.25}"],
    ["parentbased_traceidratio", "0.5", parentBased("TraceIdRatioBased{0.5}")],
    ["parentbased_traceidratio", "", parentBased("TraceIdRatioBased{1}")],
    ["traceidratio", "1.5", "TraceIdRatioBased{1}"],
    ["traceidratio", "-0.1", "TraceIdRatioBased{1}"],
    ["jaeger_remote", "", parentBased("AlwaysOnSampler")],
  ])("OTEL_TRACES_SAMPLER=%j with OTEL_TRACES_SAMPLER_ARG=%j is %s", (name, arg, expected) => {
    vi.stubEnv("OTEL_TRACES_SAMPLER", name);
    vi.stubEnv("OTEL_TRACES_SAMPLER_ARG", arg);
    expect(samplerFromEnv().toString()).toBe(expected);
  });

  it("is the sampler the SDK is configured with, inside the path filter", () => {
    vi.stubEnv("OTEL_TRACES_SAMPLER", "always_off");
    const config = telemetryConfig(testEnv, null);
    expect(config.sampler?.toString()).toBe("SkipUnrecordedPaths{AlwaysOffSampler}");
  });
});

describe("batch span processor from the environment", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  it.each([
    ["", 5000],
    ["abc", 5000],
    ["0", 0],
    ["250", 250],
  ])("OTEL_BSP_SCHEDULE_DELAY=%j sends an ended span after %d ms", async (delay, ms) => {
    vi.useFakeTimers();
    vi.stubEnv("OTEL_BSP_SCHEDULE_DELAY", delay);
    const exporter = new tracing.InMemorySpanExporter();
    const provider = new tracing.TracerProvider({ spanProcessors: [batchSpanProcessorFromEnv(exporter)] });
    provider.getTracer("test").startSpan("GET").end();
    if (ms > 0) {
      await vi.advanceTimersByTimeAsync(ms - 1);
      expect(exporter.getFinishedSpans()).toHaveLength(0);
    }
    await vi.advanceTimersByTimeAsync(ms > 0 ? 1 : 0);
    expect(exporter.getFinishedSpans()).toHaveLength(1);
    await provider.shutdown();
  });
});

describe("scrubbing", () => {
  it.each([
    ["/v/abc?next=%2Fme", "/v/abc"],
    ["http://gateway:8080/feed/explore?cursor=x#y", "http://gateway:8080/feed/explore"],
    ["fetch GET http://gateway:8080/feed/explore?cursor=x", "fetch GET http://gateway:8080/feed/explore"],
    ["https://s3.svp.localhost:8443/uploads/1?X-Amz-Signature=abc", "https://s3.svp.localhost:8443/uploads/1"],
    ["GET /following", "GET /following"],
    ["is it?", "is it?"],
    ["a?b/c?d", "a?b/c"],
    ["http://h?x", "http://h"],
    ["/a?b c /d#e /f?g\n/h", "/a c /d /f\n/h"],
  ])("removes the query of %j", (text, clean) => {
    expect(withoutQuery(text)).toBe(clean);
  });

  // Paths as long as a request line may be (Node takes 16 KiB of headers), shaped to make a backtracking URL pattern
  // retry from every "/".
  const long = "/".repeat(16 * 1024);
  const segments = "/a".repeat(8 * 1024);

  it("cuts paths of 16 KiB right", () => {
    expect(withoutQuery(long)).toBe(long);
    expect(withoutQuery(`GET ${long}?q=1 HTTP/1.1`)).toBe(`GET ${long} HTTP/1.1`);
    expect(withoutQuery("/?".repeat(8 * 1024))).toBe("/");
    expect(withoutQuery(`http://h${segments}#x ${segments}`)).toBe(`http://h${segments} ${segments}`);
    expect(withoutQuery(`${"?".repeat(16 * 1024)}/`)).toBe(`${"?".repeat(16 * 1024)}/`);
  });

  it("runs no regular expression over a span's name and attributes, which the client controls", () => {
    const provider = new tracing.TracerProvider({
      spanProcessors: [
        new ScrubbingSpanProcessor(new tracing.SimpleSpanProcessor({ exporter: new tracing.InMemorySpanExporter() })),
      ],
    });
    const tracer = provider.getTracer("test");
    // Every match of a regular expression (replace, split, test, match) goes through exec once it is replaced.
    const exec = vi.spyOn(RegExp.prototype, "exec");
    const span = tracer.startSpan(`GET ${long}`, {
      attributes: { "url.path": long, "http.target": `${segments}?q`, "user_agent.original": long },
    });
    span.setAttribute("url.full", `http://web:3000${long}`);
    span.end();
    const calls = exec.mock.calls.length;
    exec.mockRestore();
    expect(calls).toBe(0);
  });

  it("strips every query from a span's name and attributes, on start and on end", () => {
    const exporter = new tracing.InMemorySpanExporter();
    const provider = new tracing.TracerProvider({
      spanProcessors: [new ScrubbingSpanProcessor(new tracing.SimpleSpanProcessor({ exporter }))],
    });
    const tracer = provider.getTracer("test");
    // Next's fetch span names the full URL; its request span keeps the raw URL in http.target.
    const span = tracer.startSpan("fetch GET http://gateway:8080/feed/explore?cursor=secret", {
      attributes: {
        "http.target": "/v/abc?next=%2Fme",
        "http.url": "http://gateway:8080/feed/explore?cursor=secret",
        "url.query": "cursor=secret",
        "http.status_code": 200,
      },
    });
    span.setAttribute("url.full", "https://s3.svp.localhost:8443/uploads/1?X-Amz-Signature=secret");
    span.end();

    const [done] = exporter.getFinishedSpans();
    expect(done!.name).toBe("fetch GET http://gateway:8080/feed/explore");
    expect(done!.attributes).toEqual({
      "http.target": "/v/abc",
      "http.url": "http://gateway:8080/feed/explore",
      "http.status_code": 200,
      "url.full": "https://s3.svp.localhost:8443/uploads/1",
    });
  });
});

describe("resource", () => {
  it("names the service web, with the build id as its version and an id per process", async () => {
    const { exporter, tracer } = startInMemory();
    tracer.startSpan("GET").end();
    const [span] = exporter.getFinishedSpans();
    await span!.resource.waitForAsyncAttributes?.();
    const attributes = span!.resource.attributes;
    expect(attributes["service.name"]).toBe("web");
    expect(attributes["service.version"]).toBe("0123456789ab");
    expect(attributes["service.instance.id"]).toMatch(/^[0-9a-f-]{36}$/);
    expect(attributes["host.name"]).toBeUndefined();
    expect(attributes["process.command_args"]).toBeUndefined();
  });
});

describe("addTraceTags", () => {
  it("tags a server error with the trace and span of the recorded span it happened in", () => {
    const { tracer } = startInMemory();
    tracer.startActiveSpan("GET", (span) => {
      const event = addTraceTags({ tags: { service: "web", runtime: "server" } });
      expect(event.tags).toEqual({
        service: "web",
        runtime: "server",
        trace_id: span.spanContext().traceId,
        span_id: span.spanContext().spanId,
      });
      span.end();
    });
  });

  it("leaves an error outside a span, in a skipped request or from the browser untagged", () => {
    const { tracer } = startInMemory();
    expect(addTraceTags({ tags: { runtime: "server" } }).tags).toEqual({ runtime: "server" });
    tracer.startActiveSpan("GET", { attributes: { "url.path": "/monitoring" } }, (span) => {
      expect(span.isRecording()).toBe(false);
      expect(addTraceTags({ tags: { runtime: "browser" } }).tags).toEqual({ runtime: "browser" });
      expect(addTraceTags({ tags: { runtime: "server" } }).tags).toEqual({ runtime: "server" });
      span.end();
    });
    tracer.startActiveSpan("GET", (span) => {
      expect(addTraceTags({ tags: { runtime: "browser" } }).tags).toEqual({ runtime: "browser" });
      span.end();
    });
  });
});
