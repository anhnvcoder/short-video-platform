import { createServer } from "node:net";
import * as api from "@opentelemetry/api";
import * as core from "@opentelemetry/core";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { testEnv } from "../testing/bff";
import { startTelemetry } from "./otel";

// startTelemetry as instrumentation.ts calls it, configured by the OTEL_* variables only. Its own file: the
// instrumentations it hooks into Node stay for the rest of the file.

beforeEach(() => {
  vi.stubEnv("OTEL_SDK_DISABLED", "");
  vi.stubEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "");
});

afterEach(() => {
  vi.unstubAllEnvs();
  api.trace.disable();
  api.context.disable();
  api.propagation.disable();
  api.metrics.disable();
  core.setGlobalErrorHandler(core.loggingErrorHandler());
});

// A port nothing listens on: opened by the test, then closed.
async function closedPort(): Promise<number> {
  const listener = createServer();
  await new Promise<void>((resolve) => listener.listen(0, "127.0.0.1", resolve));
  const { port } = listener.address() as { port: number };
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

describe("startTelemetry", () => {
  it("does nothing when OTEL_SDK_DISABLED is true", () => {
    vi.stubEnv("OTEL_SDK_DISABLED", "true");
    vi.stubEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4317");
    expect(startTelemetry(testEnv)).toBeNull();
    expect(api.propagation.fields()).toEqual([]);
  });

  it("without an endpoint records and sends nothing, and still writes no trace context it did not make", () => {
    expect(startTelemetry(testEnv)).not.toBeNull();
    const span = api.trace.getTracer("test").startSpan("GET");
    expect(span.isRecording()).toBe(false);
    span.end();
    expect(api.metrics.getMeterProvider().getMeter("test").createHistogram("h")).toBeDefined();
    expect(api.propagation.fields()).toEqual(["traceparent", "tracestate"]);
  });

  it("keeps working when the Collector cannot be reached; a failed export is dropped", async () => {
    vi.stubEnv("OTEL_EXPORTER_OTLP_ENDPOINT", `http://127.0.0.1:${await closedPort()}`);
    vi.stubEnv("OTEL_EXPORTER_OTLP_TIMEOUT", "200");
    vi.stubEnv("OTEL_BSP_SCHEDULE_DELAY", "10");
    const errors: unknown[] = [];
    core.setGlobalErrorHandler((error) => errors.push(error));
    const sdk = startTelemetry(testEnv);
    const tracer = api.trace.getTracer("test");
    const recordSpan = () =>
      tracer.startActiveSpan("GET", (span) => {
        const recording = span.isRecording();
        span.end();
        return recording;
      });

    expect(recordSpan()).toBe(true);
    // The background export of that span fails to connect; the error goes to the SDK's error handler, not to a caller.
    await vi.waitFor(() => expect(errors).not.toHaveLength(0), { timeout: 3000 });
    expect(recordSpan()).toBe(true);
    await sdk!.shutdown().catch(() => {});
  });
});
