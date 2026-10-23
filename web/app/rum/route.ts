import { metrics } from "@opentelemetry/api";
import { WindowBudget } from "@/server/sentry/limiter";
import { handleRumBeacon } from "@/server/telemetry/rum";
import { VitalsRecorder } from "@/server/telemetry/vitals";

// Web vitals of the browser, recorded as OTel histograms (server/telemetry/rum.ts). POST only: Next answers 405 to any
// other method.
let recorder: VitalsRecorder | undefined;

const deps = {
  budget: new WindowBudget(600, 60_000),
  // Made on first use, from the meter provider instrumentation.ts registered at start: a meter taken before that
  // registration would stay a no-op for good.
  recorder: () => (recorder ??= new VitalsRecorder(metrics.getMeter("svp-web"))),
};

export function POST(request: Request): Promise<Response> {
  return handleRumBeacon(request, deps);
}
