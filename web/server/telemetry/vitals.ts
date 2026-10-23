import "server-only";
import type { Histogram, Meter } from "@opentelemetry/api";

// Web vitals the browser measures (docs/adr/0019-web-k3d-supply-chain-observability.md, section 11), recorded as one
// OTel histogram each. Bucket bounds hold web.dev's "good" and "poor" thresholds of every metric (LCP 2.5/4 s, FCP
// 1.8/3 s, TTFB 0.8/1.8 s, INP 200/500 ms, CLS 0.1/0.25), so the share of each rating reads from the buckets without a
// rating label that would triple the series.

// Bounds in seconds for the loading metrics.
const loadBuckets = [0.1, 0.2, 0.4, 0.8, 1, 1.5, 1.8, 2.5, 3, 4, 6, 10, 20];

export const vitals = {
  LCP: { instrument: "svp.web.vital.lcp", unit: "s", buckets: loadBuckets, max: 60_000 },
  FCP: { instrument: "svp.web.vital.fcp", unit: "s", buckets: loadBuckets, max: 60_000 },
  TTFB: { instrument: "svp.web.vital.ttfb", unit: "s", buckets: loadBuckets, max: 60_000 },
  INP: {
    instrument: "svp.web.vital.inp",
    unit: "s",
    buckets: [0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 2, 5],
    max: 60_000,
  },
  // Layout shift has no unit: Prometheus names it svp_web_vital_cls_*, with no suffix.
  CLS: {
    instrument: "svp.web.vital.cls",
    unit: undefined,
    buckets: [0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.25, 0.5, 1],
    max: 10,
  },
} as const satisfies Record<string, { instrument: string; unit: "s" | undefined; buckets: number[]; max: number }>;

export type VitalName = keyof typeof vitals;

export const vitalNames = Object.keys(vitals) as [VitalName, ...VitalName[]];

// The pages a beacon may come from, as route templates: the only values of the `route` label.
export type RouteTemplate = "/" | "/following" | "/login" | "/register" | "/me" | "/upload" | "/u/[handle]" | "/v/[id]";

export class VitalsRecorder {
  private readonly histograms: Record<VitalName, Histogram>;

  constructor(meter: Meter) {
    const histogram = (name: VitalName) => {
      const { instrument, unit } = vitals[name];
      return meter.createHistogram(instrument, {
        description: `${name} of a page load, measured in the browser`,
        unit,
      });
    };
    this.histograms = {
      LCP: histogram("LCP"),
      FCP: histogram("FCP"),
      TTFB: histogram("TTFB"),
      INP: histogram("INP"),
      CLS: histogram("CLS"),
    };
  }

  // `value` in the unit web-vitals reports: milliseconds, none for CLS.
  record(name: VitalName, value: number, route: RouteTemplate): void {
    this.histograms[name].record(vitals[name].unit === "s" ? value / 1000 : value, { route });
  }
}
