import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { api, metrics, tracing, type NodeSDK } from "@opentelemetry/sdk-node";
import { http, passthrough } from "msw";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { server as msw } from "@/lib/test/msw-server";
import { testEnv } from "../testing/bff";
import { startSdk, telemetryConfig } from "./otel";

// The http server as Next runs it: the server exists before the SDK starts (Next requires http and listens before
// register() runs). Its own file: the http instrumentation patches http once per process, through a hook whose cache
// another test file's SDK would have filled.

// A metric reader that keeps what it collects in memory, read on demand.
class MemoryReader extends metrics.MetricReader {
  protected onForceFlush(): Promise<void> {
    return Promise.resolve();
  }
  protected onShutdown(): Promise<void> {
    return Promise.resolve();
  }
}

const web = createServer((request, response) => {
  response.statusCode = request.url?.startsWith("/fail") ? 503 : 200;
  response.end();
});
const exporter = new tracing.InMemorySpanExporter();
const reader = new MemoryReader();
let config: ReturnType<typeof telemetryConfig>;
let sdk: NodeSDK;
let origin: string;

beforeAll(async () => {
  await new Promise<void>((resolve) => web.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${(web.address() as AddressInfo).port}`;
  config = telemetryConfig(testEnv, { spans: new tracing.SimpleSpanProcessor(exporter), metrics: reader });
  sdk = startSdk(config);
});

afterAll(async () => {
  for (const instrumentation of config.instrumentations.flat()) {
    instrumentation.disable();
  }
  await sdk.shutdown();
  await new Promise((resolve) => web.close(resolve));
  api.trace.disable();
  api.context.disable();
  api.propagation.disable();
  api.metrics.disable();
});

// Server spans of the http instrumentation, by path.
function serverSpans() {
  return exporter
    .getFinishedSpans()
    .filter((span) => span.instrumentationScope.name === "@opentelemetry/instrumentation-http")
    .filter((span) => span.kind === api.SpanKind.SERVER);
}

async function durations() {
  const { resourceMetrics } = await reader.collect();
  const metric = resourceMetrics.scopeMetrics
    .flatMap((scope) => scope.metrics)
    .find((found) => found.descriptor.name === "http.server.request.duration");
  return (metric?.dataPoints ?? []).map((point) => ({
    attributes: point.attributes,
    count: (point.value as { count: number }).count,
  }));
}

describe("http server started before the SDK", () => {
  it("records a server span per request worth a trace and a duration for every response", async () => {
    // The test's own server on loopback, not the network: let these requests through the interceptor.
    msw.use(http.all(`${origin}/*`, () => passthrough()));
    const page = await fetch(`${origin}/v/abc?next=%2Fme`, {
      headers: { traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
    });
    const probe = await fetch(`${origin}/healthz`);
    const failed = await fetch(`${origin}/fail`);
    expect([page.status, probe.status, failed.status]).toEqual([200, 200, 503]);

    // A span ends when its response has finished on the server, which may come after the client has read it.
    await vi.waitFor(() => expect(serverSpans()).toHaveLength(2));
    const spans = serverSpans();
    expect(spans.map((span) => span.attributes["url.path"])).toEqual(["/v/abc", "/fail"]);
    // A new root per request: the client's traceparent is not read (inject-only), and no query is kept.
    expect(spans[0]!.spanContext().traceId).not.toBe("4bf92f3577b34da6a3ce929d0e0e4736");
    expect(spans[0]!.parentSpanContext).toBeUndefined();
    expect(JSON.stringify(spans[0]!.attributes)).not.toContain("next=");

    // The probe has no span but counts, as every response does; no path or route among the attributes.
    const points = await durations();
    expect(points.map((point) => [point.attributes["http.response.status_code"], point.count]).sort()).toEqual([
      [200, 2],
      [503, 1],
    ]);
    for (const point of points) {
      expect(Object.keys(point.attributes).sort()).toEqual(
        expect.arrayContaining(["http.request.method", "http.response.status_code", "url.scheme"]),
      );
      expect(Object.keys(point.attributes).filter((key) => key.startsWith("url.path") || key === "http.route")).toEqual(
        [],
      );
    }
  });
});
