import { serverEnv } from "@/server/env";
import { WindowBudget } from "@/server/sentry/limiter";
import { handleMonitoringReport } from "@/server/sentry/monitoring";
import { captureBrowserReport } from "@/server/sentry/server";

// Error reports of the browser, sent to GlitchTip by the server (server/sentry/monitoring.ts). POST only: Next answers
// 405 to any other method.
const deps = { budget: new WindowBudget(20, 60_000), capture: captureBrowserReport };

export function POST(request: Request): Promise<Response> {
  return handleMonitoringReport(request, serverEnv(), deps);
}
