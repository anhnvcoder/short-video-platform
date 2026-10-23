import * as Sentry from "@sentry/nextjs";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { testEnv } from "../testing/bff";
import type { BrowserReport } from "./browser-report";
import { WindowBudget } from "./limiter";
import { handleMonitoringReport } from "./monitoring";
import { captureBrowserReport, startErrorReporting } from "./server";

// The SDK as the server runs it, with an in-memory transport in place of GlitchTip.

const env = {
  ...testEnv,
  appOrigin: "https://svp.localhost:8443",
  sentryDsn: "http://0123abcd@glitchtip.test:8000/1",
  sentryEnvironment: "k3d",
  buildId: "dev-0123456789ab",
};
const sid = Buffer.alloc(32, 7).toString("base64url");

const sent: { url: string; body: string }[] = [];
// "hang": GlitchTip accepts the connection and never answers.
let upstream: "ok" | "hang" = "ok";

beforeAll(() => {
  startErrorReporting(env, (options) =>
    Sentry.createTransport(options, async (request) => {
      sent.push({ url: options.url, body: String(request.body) });
      if (upstream === "hang") {
        await new Promise(() => {});
      }
      return { statusCode: 200 };
    }),
  );
});

// 0 would mean no timeout, and the last test leaves a request hanging.
afterAll(() => Sentry.close(100));

beforeEach(() => {
  sent.length = 0;
});

interface SentEvent {
  platform?: string;
  message?: string;
  environment?: string;
  release?: string;
  request?: unknown;
  tags?: Record<string, string>;
  contexts?: Record<string, unknown>;
  exception?: { values: { type: string; value: string }[] };
  debug_meta?: unknown;
}

// The events of the envelopes sent: each envelope is a header line, then an item header and its payload.
async function sentEvents(): Promise<SentEvent[]> {
  await Sentry.flush(2_000);
  return sent.flatMap(({ body }) => {
    const [, itemHeader, payload] = body.split("\n");
    return JSON.parse(itemHeader ?? "{}").type === "event" ? [JSON.parse(payload ?? "{}") as SentEvent] : [];
  });
}

const report: BrowserReport = {
  name: "TypeError",
  message: "no profile for minh@example.com",
  stack: "    at Profile (https://svp.localhost:8443/_next/static/chunks/0khh50nt3ldfz.js:1:99)",
  path: "/u/minhanh",
  debug_ids: {
    "https://svp.localhost:8443/_next/static/chunks/0khh50nt3ldfz.js": "8f1c2a4e-5b6d-4e7f-9a0b-1c2d3e4f5a6b",
  },
};

describe("server error reporting", () => {
  it("reports a request error to the DSN's envelope endpoint, scrubbed, without withSentryConfig", async () => {
    Sentry.captureRequestError(
      new Error(`session ${sid} of minh@example.com expired`),
      {
        path: "/login?next=/me",
        method: "POST",
        headers: { cookie: `svp_sid=${sid}`, "x-forwarded-for": "203.0.113.9" },
      },
      { routerKind: "App Router", routePath: "/login", routeType: "action" },
    );
    const events = await sentEvents();
    expect(sent[0]?.url).toMatch(/^http:\/\/glitchtip\.test:8000\/api\/1\/envelope\//);
    expect(events).toHaveLength(1);
    const [event] = events;
    expect(event?.exception?.values[0]).toMatchObject({
      type: "Error",
      value: "session [redacted] of [redacted] expired",
    });
    expect(event).toMatchObject({
      environment: "k3d",
      release: "dev-0123456789ab",
      tags: { service: "web", runtime: "server" },
      contexts: { nextjs: { request_path: "/login", route_type: "action" } },
    });
    expect(event).not.toHaveProperty("request");
    expect(event).not.toHaveProperty("server_name");
    for (const leak of [sid, "minh@example.com", "203.0.113.9", "cookie", "next=/me"]) {
      expect(sent[0]?.body).not.toContain(leak);
    }
  });

  it("sends the same server error once in 30 s", async () => {
    for (let i = 0; i < 3; i++) {
      Sentry.captureException(new Error("gateway unreachable"));
    }
    expect(await sentEvents()).toHaveLength(1);
  });

  it("keeps a browser report's platform and debug ids, and scrubs it like any event", async () => {
    captureBrowserReport(report, env);
    const [event] = await sentEvents();
    expect(event).toMatchObject({
      platform: "javascript",
      request: { url: "https://svp.localhost:8443/u/minhanh" },
      tags: { service: "web", runtime: "browser", route: "/u/[handle]" },
      exception: { values: [{ type: "TypeError", value: "no profile for [redacted]" }] },
      debug_meta: {
        images: [
          {
            type: "sourcemap",
            code_file: "https://svp.localhost:8443/_next/static/chunks/0khh50nt3ldfz.js",
            debug_id: "8f1c2a4e-5b6d-4e7f-9a0b-1c2d3e4f5a6b",
          },
        ],
      },
    });
  });

  // Last: the hung request stays pending in the transport until the SDK closes.
  it("answers a browser's report at once while GlitchTip hangs", async () => {
    upstream = "hang";
    const deps = { budget: new WindowBudget(20, 60_000), capture: captureBrowserReport };
    const request = new Request("http://localhost:3001/monitoring", {
      method: "POST",
      body: JSON.stringify({ ...report, message: "hangs" }),
    });
    const started = performance.now();
    const response = await handleMonitoringReport(request, env, deps);
    expect(response.status).toBe(202);
    expect(performance.now() - started).toBeLessThan(500);
    // The SDK tried to send it.
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(sent).toHaveLength(1);
  });
});
