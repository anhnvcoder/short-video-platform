import "server-only";
import type { ServerEnv } from "../env";
import { problem } from "../problem";
import { browserReportSchema, type BrowserReport } from "./browser-report";
import { WindowBudget } from "./limiter";

// POST /monitoring: a browser's error report. proxy.ts
// has already checked it comes from the app's own pages (CSRF); this checks the report and hands it to the SDK.

export const maxReportBytes = 32 * 1024;

export interface MonitoringDeps {
  // Browser reports of this process: 20 a minute, whoever sends them (all clients may share one or two addresses).
  budget: WindowBudget;
  capture(report: BrowserReport, env: ServerEnv): void;
}

// The body as text, or null when it is larger than the limit.
async function readText(request: Request): Promise<string | null> {
  if (Number(request.headers.get("content-length") ?? 0) > maxReportBytes) {
    return null;
  }
  if (request.body === null) {
    return "";
  }
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    size += value.byteLength;
    if (size > maxReportBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

export async function handleMonitoringReport(
  request: Request,
  env: ServerEnv,
  { budget, capture }: MonitoringDeps,
): Promise<Response> {
  // Reporting is off: the browser stops sending for the rest of the page.
  if (env.sentryDsn === null) {
    return problem(404, "NOT_FOUND");
  }
  const text = await readText(request);
  if (text === null) {
    return problem(413, "PAYLOAD_TOO_LARGE");
  }
  // The body is JSON sent as text/plain (a type a form could send too: proxy.ts's origin check is what keeps other
  // sites out), so the media type is not checked.
  const report = browserReportSchema.safeParse(parseJson(text));
  if (!report.success) {
    return problem(400, "INVALID_REPORT");
  }
  if (!budget.take()) {
    return problem(429, "RATE_LIMITED", { "Retry-After": "60" });
  }
  capture(report.data, env);
  return new Response(null, { status: 202, headers: { "Cache-Control": "no-store" } });
}
