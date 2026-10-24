import * as api from "@opentelemetry/api";
import * as metrics from "@opentelemetry/sdk-metrics";
import { afterEach, describe, expect, it } from "vitest";
import * as route from "./route";

class MemoryReader extends metrics.MetricReader {
  protected onForceFlush(): Promise<void> {
    return Promise.resolve();
  }
  protected onShutdown(): Promise<void> {
    return Promise.resolve();
  }
}

afterEach(() => {
  api.metrics.disable();
});

describe("/rum", () => {
  it("exports POST only, so Next answers 405 to GET and every other method", () => {
    expect(Object.keys(route)).toEqual(["POST"]);
  });

  it("records into the meter provider registered after the module loaded", async () => {
    // instrumentation.ts registers the provider at start; a meter taken when the module loaded would be a no-op.
    const reader = new MemoryReader();
    api.metrics.setGlobalMeterProvider(new metrics.MeterProvider({ readers: [reader] }));
    const response = await route.POST(
      new Request("http://localhost:3001/rum", {
        method: "POST",
        body: JSON.stringify({ path: "/login", metrics: [{ name: "CLS", value: 0.05 }] }),
      }),
    );
    expect(response.status).toBe(204);
    const { resourceMetrics } = await reader.collect();
    const names = resourceMetrics.scopeMetrics.flatMap((scope) => scope.metrics.map((m) => m.descriptor.name));
    expect(names).toEqual(["svp.web.vital.cls"]);
  });
});
