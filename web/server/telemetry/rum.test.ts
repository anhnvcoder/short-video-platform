import { metrics } from "@opentelemetry/sdk-node";
import { describe, expect, it } from "vitest";
import { WindowBudget } from "../sentry/limiter";
import { vitalViews } from "./otel";
import { handleRumBeacon, maxBeaconBytes, routeOf } from "./rum";
import { VitalsRecorder } from "./vitals";

// A metric reader that keeps what it collects in memory, read on demand.
class MemoryReader extends metrics.MetricReader {
  protected onForceFlush(): Promise<void> {
    return Promise.resolve();
  }
  protected onShutdown(): Promise<void> {
    return Promise.resolve();
  }
}

const videoId = "0b7c9a2e-1f3d-4e5a-8b6c-7d8e9f0a1b2c";

function setup(limit = 600) {
  const reader = new MemoryReader();
  const provider = new metrics.MeterProvider({ readers: [reader], views: vitalViews });
  const recorder = new VitalsRecorder(provider.getMeter("test"));
  return { reader, deps: { budget: new WindowBudget(limit, 60_000), recorder: () => recorder } };
}

interface Point {
  route: unknown;
  count: number;
  sum: number;
  boundaries: number[];
  counts: number[];
}

// Every histogram the reader holds, by instrument name, with its unit and one entry per route.
async function histograms(reader: MemoryReader) {
  const { resourceMetrics } = await reader.collect();
  const found = new Map<string, { unit: string; points: Point[] }>();
  for (const metric of resourceMetrics.scopeMetrics.flatMap((scope) => scope.metrics)) {
    const points = metric.dataPoints.map((point) => {
      const value = point.value as { count: number; sum: number; buckets: { boundaries: number[]; counts: number[] } };
      return {
        route: point.attributes.route,
        count: value.count,
        sum: value.sum,
        boundaries: value.buckets.boundaries,
        counts: value.buckets.counts,
      };
    });
    found.set(metric.descriptor.name, { unit: metric.descriptor.unit, points });
  }
  return found;
}

function post(body: BodyInit | null): Request {
  return new Request("http://localhost:3001/rum", {
    method: "POST",
    body,
    headers: { "Content-Type": "text/plain;charset=UTF-8" },
  });
}

const beacon = (path: string, values: { name: string; value: unknown }[]) =>
  post(JSON.stringify({ path, metrics: values }));

describe("POST /rum", () => {
  it("records each metric in its histogram, in seconds or without unit, labelled with the route template; 204", async () => {
    const { reader, deps } = setup();
    const response = await handleRumBeacon(
      beacon(`/v/${videoId}`, [
        { name: "LCP", value: 1830.4 },
        { name: "INP", value: 120 },
        { name: "CLS", value: 0.02 },
        { name: "FCP", value: 900 },
        { name: "TTFB", value: 250 },
      ]),
      deps,
    );
    expect(response.status).toBe(204);
    expect(response.headers.get("cache-control")).toBe("no-store");

    const found = await histograms(reader);
    expect([...found.keys()].sort()).toEqual([
      "svp.web.vital.cls",
      "svp.web.vital.fcp",
      "svp.web.vital.inp",
      "svp.web.vital.lcp",
      "svp.web.vital.ttfb",
    ]);
    const lcp = found.get("svp.web.vital.lcp")!;
    expect(lcp.unit).toBe("s");
    expect(lcp.points).toEqual([
      {
        route: "/v/[id]",
        count: 1,
        sum: 1.8304,
        boundaries: [0.1, 0.2, 0.4, 0.8, 1, 1.5, 1.8, 2.5, 3, 4, 6, 10, 20],
        counts: [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0],
      },
    ]);
    const inp = found.get("svp.web.vital.inp")!;
    expect(inp.unit).toBe("s");
    expect(inp.points[0]).toMatchObject({
      sum: 0.12,
      boundaries: [0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 2, 5],
    });
    const cls = found.get("svp.web.vital.cls")!;
    expect(cls.unit).toBe("");
    expect(cls.points[0]).toMatchObject({
      sum: 0.02,
      boundaries: [0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.25, 0.5, 1],
    });
    expect(found.get("svp.web.vital.fcp")!.points[0]).toMatchObject({
      sum: 0.9,
      boundaries: lcp.points[0]!.boundaries,
    });
    expect(found.get("svp.web.vital.ttfb")!.points[0]).toMatchObject({ sum: 0.25 });
  });

  it.each([
    ["/", "/"],
    ["/following", "/following"],
    ["/login", "/login"],
    ["/register", "/register"],
    ["/me", "/me"],
    ["/upload", "/upload"],
    ["/u/an_nguyen", "/u/[handle]"],
    ["/u/u_0123456789ab", "/u/[handle]"],
    [`/v/${videoId}`, "/v/[id]"],
  ])("maps %s to the route %s", (path, route) => {
    expect(routeOf(path)).toBe(route);
  });

  it.each([
    "/api/feed/explore",
    "/login/",
    "/u/An",
    "/u/ab",
    "/u/an/videos",
    `/v/${videoId.toUpperCase()}`,
    "/v/not-a-uuid",
    `/v/${videoId}/x`,
    "/monitoring",
    "",
    "https://evil.example/",
  ])("drops a beacon from %j whole: 204, no series", async (path) => {
    const { reader, deps } = setup();
    expect(routeOf(path)).toBeNull();
    const response = await handleRumBeacon(beacon(path, [{ name: "LCP", value: 1000 }]), deps);
    expect(response.status).toBe(204);
    expect((await histograms(reader)).size).toBe(0);
  });

  it("drops a negative value or one above the ceiling, keeps the rest of the beacon", async () => {
    const { reader, deps } = setup();
    const response = await handleRumBeacon(
      beacon("/", [
        { name: "LCP", value: -1 },
        { name: "INP", value: 60_001 },
        { name: "CLS", value: 10.5 },
        { name: "FCP", value: 60_000 },
        { name: "TTFB", value: 0 },
      ]),
      deps,
    );
    expect(response.status).toBe(204);
    const found = await histograms(reader);
    expect([...found.keys()].sort()).toEqual(["svp.web.vital.fcp", "svp.web.vital.ttfb"]);
    expect(found.get("svp.web.vital.fcp")!.points[0]).toMatchObject({ route: "/", sum: 60 });
  });

  it.each([
    ["an empty body", ""],
    ["text that is not JSON", "LCP=1000"],
    ["JSON that is not an object", "[1, 2]"],
    ["no metrics", JSON.stringify({ path: "/", metrics: [] })],
    [
      "six metrics",
      JSON.stringify({ path: "/", metrics: Array.from({ length: 6 }, () => ({ name: "LCP", value: 1 })) }),
    ],
    [
      "a metric twice",
      JSON.stringify({
        path: "/",
        metrics: [
          { name: "LCP", value: 1 },
          { name: "LCP", value: 2 },
        ],
      }),
    ],
    ["an unknown metric", JSON.stringify({ path: "/", metrics: [{ name: "FID", value: 1 }] })],
    [
      "a null value (NaN and Infinity become null in JSON)",
      JSON.stringify({ path: "/", metrics: [{ name: "LCP", value: Number.NaN }] }),
    ],
    ["a value given as text", JSON.stringify({ path: "/", metrics: [{ name: "LCP", value: "1000" }] })],
    ["no path", JSON.stringify({ metrics: [{ name: "LCP", value: 1 }] })],
    [
      "a path over 500 characters",
      JSON.stringify({ path: `/${"a".repeat(500)}`, metrics: [{ name: "LCP", value: 1 }] }),
    ],
  ])("refuses %s: 400 INVALID_BEACON, nothing recorded", async (_name, body) => {
    const { reader, deps } = setup();
    const response = await handleRumBeacon(post(body), deps);
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ code: "INVALID_BEACON" });
    expect((await histograms(reader)).size).toBe(0);
  });

  it("refuses a body over 4 KiB by its Content-Length: 413", async () => {
    const { reader, deps } = setup();
    const body = JSON.stringify({ path: "/", metrics: [{ name: "LCP", value: 1 }], pad: "x".repeat(maxBeaconBytes) });
    const response = await handleRumBeacon(post(body), deps);
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ code: "PAYLOAD_TOO_LARGE" });
    expect((await histograms(reader)).size).toBe(0);
  });

  it("refuses a streamed body over 4 KiB without a Content-Length, and stops reading it", async () => {
    const { deps } = setup();
    const bytes = new TextEncoder().encode("x".repeat(512));
    let pushed = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pushed++;
        controller.enqueue(bytes);
      },
    });
    const request = new Request("http://localhost:3001/rum", {
      method: "POST",
      body: stream,
      duplex: "half",
    } as RequestInit);
    const response = await handleRumBeacon(request, deps);
    expect(response.status).toBe(413);
    expect(pushed).toBeLessThan(20);
  });

  it("answers 429 past 600 beacons a minute of the process, and records none of them", async () => {
    const { reader, deps } = setup(2);
    for (let i = 0; i < 2; i++) {
      expect((await handleRumBeacon(beacon("/", [{ name: "LCP", value: 1000 }]), deps)).status).toBe(204);
    }
    const refused = await handleRumBeacon(beacon("/", [{ name: "LCP", value: 1000 }]), deps);
    expect(refused.status).toBe(429);
    expect(refused.headers.get("retry-after")).toBe("60");
    expect((await histograms(reader)).get("svp.web.vital.lcp")!.points[0]!.count).toBe(2);
  });
});
