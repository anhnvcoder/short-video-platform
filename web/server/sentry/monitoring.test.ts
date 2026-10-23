import { describe, expect, it, vi } from "vitest";
import { testEnv } from "../testing/bff";
import type { BrowserReport } from "./browser-report";
import { WindowBudget } from "./limiter";
import { handleMonitoringReport, maxReportBytes } from "./monitoring";

const env = { ...testEnv, sentryDsn: "http://0123abcd@glitchtip.test:8000/1" };

const report: BrowserReport = {
  name: "TypeError",
  message: "x is undefined",
  stack: "    at f (http://localhost:3001/_next/static/chunks/a.js:1:2)",
  path: "/",
  debug_ids: {},
};

function post(body: BodyInit | null, headers: Record<string, string> = { "Content-Type": "text/plain" }): Request {
  return new Request("http://localhost:3001/monitoring", { method: "POST", body, headers });
}

function deps(limit = 20) {
  return { budget: new WindowBudget(limit, 60_000), capture: vi.fn<(report: BrowserReport) => void>() };
}

describe("POST /monitoring", () => {
  it("hands a valid report to the SDK and answers 202 at once", async () => {
    const d = deps();
    const response = await handleMonitoringReport(post(JSON.stringify(report)), env, d);
    expect(response.status).toBe(202);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(d.capture).toHaveBeenCalledExactlyOnceWith(report, env);
  });

  it("answers 404 when reporting is off, before reading anything", async () => {
    const d = deps();
    const response = await handleMonitoringReport(post(JSON.stringify(report)), { ...env, sentryDsn: null }, d);
    expect(response.status).toBe(404);
    expect(d.capture).not.toHaveBeenCalled();
  });

  it("refuses a body over 32 KiB by its Content-Length", async () => {
    const d = deps();
    const big = JSON.stringify({ ...report, stack: "x".repeat(maxReportBytes) });
    const response = await handleMonitoringReport(post(big), env, d);
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ code: "PAYLOAD_TOO_LARGE" });
    expect(d.capture).not.toHaveBeenCalled();
  });

  it("refuses a streamed body over 32 KiB without a Content-Length", async () => {
    const d = deps();
    const bytes = new TextEncoder().encode("x".repeat(1_024));
    let pushed = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pushed++;
        controller.enqueue(bytes);
      },
    });
    const request = new Request("http://localhost:3001/monitoring", {
      method: "POST",
      body: stream,
      duplex: "half",
    } as RequestInit);
    const response = await handleMonitoringReport(request, env, d);
    expect(response.status).toBe(413);
    // It stopped reading right after the limit.
    expect(pushed).toBeLessThan(40);
    expect(d.capture).not.toHaveBeenCalled();
  });

  it.each<[string, string]>([
    ["not JSON", "TypeError: x is undefined"],
    ["an empty body", ""],
    ["a report missing a field", JSON.stringify({ ...report, path: undefined })],
    ["a report with a field too long", JSON.stringify({ ...report, message: "x".repeat(1_001) })],
    ["a Sentry envelope", `{"dsn":"http://0123abcd@glitchtip.test:8000/1"}\n{"type":"event"}\n{}`],
  ])("answers 400 to %s", async (_case, body) => {
    const d = deps();
    const response = await handleMonitoringReport(post(body), env, d);
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ code: "INVALID_REPORT" });
    expect(d.capture).not.toHaveBeenCalled();
  });

  it("answers 429 past the browsers' budget, without sending", async () => {
    const d = deps(2);
    for (let i = 0; i < 2; i++) {
      expect((await handleMonitoringReport(post(JSON.stringify(report)), env, d)).status).toBe(202);
    }
    const response = await handleMonitoringReport(post(JSON.stringify(report)), env, d);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(d.capture).toHaveBeenCalledTimes(2);
  });

  it("does not spend the budget on an invalid report", async () => {
    const d = deps(1);
    await handleMonitoringReport(post("not json"), env, d);
    expect((await handleMonitoringReport(post(JSON.stringify(report)), env, d)).status).toBe(202);
  });
});
