import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { authedTest, expect, feedItem, testResultsDir } from "./fixtures";
import { stack } from "./stack";

// A browser error of the real bundle reaches GlitchTip with its stack mapped to the source.
// Only with SVP_E2E_GLITCHTIP=1
// (playwright.config.ts), on a stack whose GlitchTip holds the source maps of the build the web serves: compose `make
// up OBS=lgtm` then `make web-sourcemaps`, or k3d `make k8s-web-sourcemaps` then `make k8s-web-e2e`.
//
// The error comes from no debug path of the app: the next page of Explore is answered with one item whose title is an
// object instead of text, and React, rendering that title, throws to the error boundary of app/error.tsx, which reports
// it through POST /monitoring. Every client call of the app checks the fields it uses itself and catches what fails, so
// a malformed answer cannot make the app's own code throw; the frames are React's, mapped to its source under
// node_modules of the web project.
//
// The GlitchTip API is read with the read-only token (event:read, project:read), never printed: compose takes
// SENTRY_AUTH_TOKEN of .env (read with deploy/observability/glitchtip/dotenv.sh), k3d gets the token of Secret
// svp-obs/glitchtip-api from e2e/k3d-e2e.sh in SVP_E2E_GLITCHTIP_TOKEN. GlitchTip is on 127.0.0.1:8000 on both:
// compose publishes it there, e2e/k3d-e2e.sh opens a port-forward there for the run. Each browser's event, once found,
// goes to test-results/glitchtip-<project>.json (with the environment GlitchTip holds for it), which `make
// drill-k8s-web-obs` reads back.

const glitchtipURL = "http://127.0.0.1:8000";
// Organization and project that GlitchTip's bootstrap creates on both stacks.
const projectPath = "/api/0/projects/svp/svp";
// GlitchTip stores an event once its task worker has processed it: polled every 5 s for at most this long.
const eventTimeoutMs = 180_000;

// Frames GlitchTip mapped to a file of the web project: Turbopack names the sources of its maps
// turbopack:///[project]/<path in web/>. A frame left unmapped keeps the chunk's URL under /_next/static/.
const webSource = /(^|\/)\[project\]\/|^web\//;

function apiToken(): string {
  const fromRun = process.env.SVP_E2E_GLITCHTIP_TOKEN;
  if (fromRun) {
    return fromRun;
  }
  if (stack.name === "k3d") {
    throw new Error("SVP_E2E_GLITCHTIP_TOKEN is not set: run make k8s-web-e2e, which reads it from the cluster");
  }
  const repo = join(import.meta.dirname, "..", "..");
  const token = execFileSync(
    "bash",
    [
      "-c",
      '. "$1" && dotenv_value "$2" SENTRY_AUTH_TOKEN',
      "bash",
      join(repo, "deploy/observability/glitchtip/dotenv.sh"),
      join(repo, ".env"),
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  );
  if (!token) {
    throw new Error(
      "SENTRY_AUTH_TOKEN is missing or empty in .env; run make up OBS=lgtm (or make glitchtip-init) first",
    );
  }
  return token;
}

async function glitchtip<T>(token: string, path: string): Promise<T> {
  const response = await fetch(`${glitchtipURL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    throw new Error(`GlitchTip GET ${path.split("?")[0]} answered ${response.status}`);
  }
  return (await response.json()) as T;
}

type Tag = { key: string; value: string };
type Issue = { id: string; lastSeen: string };
type EventSummary = { event_id: string; date_received: string; tags?: Tag[] };
type Frame = { filename?: string; absPath?: string; abs_path?: string; function?: string };
type ExceptionValue = { type?: string; value?: string; stacktrace?: { frames?: Frame[] } };
type EventDetail = {
  tags?: Tag[];
  environment?: string;
  entries?: { type: string; data?: { values?: ExceptionValue[] } }[];
  exception?: { values?: ExceptionValue[] };
};

function tag(tags: Tag[] | undefined, key: string): string | undefined {
  return tags?.find((candidate) => candidate.key === key)?.value;
}

// The exception of an event as the API returns it: under entries (Sentry's API form) or exception (the stored one).
function exceptionOf(event: EventDetail): ExceptionValue | undefined {
  const fromEntries = event.entries?.filter((entry) => entry.type === "exception").flatMap((e) => e.data?.values ?? []);
  return fromEntries?.[0] ?? event.exception?.values?.[0];
}

function sourceOf(frame: Frame): string {
  return frame.filename || frame.absPath || frame.abs_path || "";
}

type Found = { issueId: string; eventId: string; type: string; environment: string; sources: string[] };

// The events of the web's browser reports received since `since` (ms since the epoch) on the feed's route, newest
// issue first, with their exception and frame sources.
async function browserEvents(token: string, since: number): Promise<Found[]> {
  const found: Found[] = [];
  const issues = await glitchtip<Issue[]>(
    token,
    `${projectPath}/issues/?query=${encodeURIComponent("runtime:browser")}`,
  );
  for (const issue of issues.filter((candidate) => Date.parse(candidate.lastSeen) >= since)) {
    if (!/^[0-9]+$/.test(issue.id)) {
      continue;
    }
    const events = await glitchtip<EventSummary[]>(token, `/api/0/issues/${issue.id}/events/`);
    for (const event of events) {
      if (
        !/^[0-9a-f]{32}$/.test(event.event_id) ||
        Date.parse(event.date_received) < since ||
        tag(event.tags, "service") !== "web" ||
        tag(event.tags, "route") !== "/"
      ) {
        continue;
      }
      const detail = await glitchtip<EventDetail>(token, `${projectPath}/events/${event.event_id}/`);
      const exception = exceptionOf(detail);
      found.push({
        issueId: issue.id,
        eventId: event.event_id,
        type: exception?.type ?? "",
        // Sentry's API lists the event's environment among its tags; the stored event has it as a field of its own.
        environment: tag(detail.tags, "environment") ?? detail.environment ?? "",
        sources: (exception?.stacktrace?.frames ?? []).map(sourceOf),
      });
    }
  }
  return found;
}

function isNextPageRequest(url: URL): boolean {
  return url.pathname === "/api/feed/explore" && url.searchParams.has("cursor");
}

authedTest(
  "a browser error reaches GlitchTip with its stack mapped to the web's source",
  async ({ page }, testInfo) => {
    testInfo.setTimeout(eventTimeoutMs + 60_000);
    const token = apiToken();
    const health = await fetch(`${glitchtipURL}/_health/`, { signal: AbortSignal.timeout(5000) }).catch(() => null);
    expect(health?.ok, `GlitchTip answers at ${glitchtipURL}`).toBe(true);
    // GlitchTip's clock is this machine's (compose) or the cluster's on it (k3d): a few seconds of slack.
    const since = Date.now() - 5000;

    await page.route(isNextPageRequest, async (route) => {
      const response = await route.fetch();
      const body = (await response.json()) as { items: Record<string, unknown>[] };
      if (body.items[0]) {
        body.items[0].title = { e2e: "a title that is not text" };
      }
      await route.fulfill({ response, json: body });
    });
    const report = page.waitForRequest(
      (request) => request.method() === "POST" && new URL(request.url()).pathname === "/monitoring",
    );

    await page.goto("/");
    await expect(feedItem(page, 0)).toBeVisible();
    const pageSize = await page.locator('[role="feed"] > article [data-part="video-host"]').count();
    expect(pageSize).toBeGreaterThan(2);
    // One of the last two videos asks for the next page, whose malformed item then renders.
    await feedItem(page, pageSize - 2).evaluate((item) => item.scrollIntoView({ block: "start", behavior: "instant" }));
    // The error boundary's heading, not a video's own error, whose text starts the same way.
    await expect(page.getByRole("heading", { level: 1, name: "Something went wrong", exact: true })).toBeVisible();

    const sent = await report;
    expect((await sent.response())?.status(), "POST /monitoring is accepted").toBe(202);
    const reported = JSON.parse(sent.postData() ?? "{}") as { name: string; debug_ids: Record<string, string> };
    // Without a debug id per chunk of the stack, GlitchTip has nothing to find the maps by.
    expect(Object.keys(reported.debug_ids).length, "debug ids of the chunks in the stack").toBeGreaterThan(0);

    let unmapped: Found | undefined;
    let mapped: Found | undefined;
    const deadline = Date.now() + eventTimeoutMs;
    for (;;) {
      const events = (await browserEvents(token, since)).filter((event) => event.type === reported.name);
      mapped = events.find((event) => event.sources.some((source) => webSource.test(source)));
      unmapped ??= events[0];
      if (mapped || Date.now() >= deadline) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
    if (!mapped) {
      throw new Error(
        unmapped
          ? `GlitchTip event ${unmapped.eventId} (issue ${unmapped.issueId}) has no frame mapped to the web's source ` +
              `(frames ${unmapped.sources.slice(0, 3).join(", ")}): upload the source maps of the build the web ` +
              `serves first (${stack.name === "k3d" ? "make k8s-web-sourcemaps" : "make web-sourcemaps"}), then run again`
          : `no GlitchTip event of this ${reported.name} report within ${eventTimeoutMs / 1000} s: check the web's ` +
              `SENTRY_DSN and GlitchTip's worker; the same error on the same web process within 30 s is dropped by its ` +
              `per-fingerprint limit, so run again after 30 s`,
      );
    }

    const appFrames = mapped.sources.filter((source) => webSource.test(source) && !source.includes("node_modules"));
    const result = {
      stack: stack.name,
      project: testInfo.project.name,
      found_at: new Date().toISOString(),
      event_id: mapped.eventId,
      issue_id: mapped.issueId,
      exception_type: mapped.type,
      environment: mapped.environment,
      mapped_frames: mapped.sources.filter((source) => webSource.test(source)).length,
      app_frames: appFrames.length,
      frames: mapped.sources,
    };
    mkdirSync(testResultsDir, { recursive: true });
    writeFileSync(
      join(testResultsDir, `glitchtip-${testInfo.project.name}.json`),
      `${JSON.stringify(result, null, 2)}\n`,
    );
    console.log(
      `GlitchTip event ${mapped.eventId} (issue ${mapped.issueId}): ${result.mapped_frames} of ` +
        `${mapped.sources.length} frames mapped to the web's source, ${appFrames.length} of them the app's own`,
    );
  },
);
