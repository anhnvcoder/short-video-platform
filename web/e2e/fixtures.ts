import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync } from "node:fs";
import { join } from "node:path";
import { test as base, expect, type BrowserContext, type Locator, type Page } from "@playwright/test";
import { stack } from "./stack";

// Shared helpers of the end-to-end tests.
//
// Rate limits: the BFF reaches the gateway from the one address of the `web` container, so all browsers share the
// gateway's per-IP buckets: register (burst 20 per hour), login-ip (burst 30,
// 60 per minute). Test users are therefore registered straight at the gateway, and each project logs in through the
// web about 8 times and registers through it once (the main flow); e2e/seed.sh resets the register bucket before every
// run. Each user logs in at most 3 times, under the login-email burst of 5. Registering at the gateway uses the bucket
// of this machine, also a burst of 20 refilled one a minute: a whole run registers more users than that within a few
// minutes (28 in an evidence run), so every worker resets the register buckets again before its first test (the
// registerLimitReset fixture, LOCAL LAB ONLY). A worker runs one project, at most 9 registrations (chromium or webkit in
// an evidence run, its sessionAccount included); a new test still reuses the worker's sessionAccount when it can. On
// k3d every registration of a worker, through the BFF or straight at the gateway, lands in one bucket: the BFF passes
// X-Forwarded-For on as it received it and the gateway reads the address Envoy wrote (server/gateway.ts), the same for
// both. The budget is tighter there than on compose; the reset before each worker's first test keeps it under the burst.

// The gateway as e2e/seed.sh reaches it: its loopback port on compose, through Envoy on k3d (e2e/stack.ts).
export const gatewayURL = stack.gatewayURL;

export type Credentials = { email: string; password: string };
export type Account = Credentials & { handle: string; userId: string };

// A handle of the form people choose, random per call.
export function randomHandle(): string {
  return `e2e_${randomBytes(6).toString("hex")}`;
}

// The handle user-service gives a user registered without one: u_ and the last 12 hex digits of the id.
// The seeded authors of e2e/seed.sh have such handles, and their display name is the same text.
export function generatedHandle(userId: string): string {
  return `u_${userId.slice(-12)}`;
}

// A fresh random user with a handle of its own, registered at the gateway. Every run gets new users, so no test
// depends on an earlier run.
export async function registerAccount(): Promise<Account> {
  const credentials = {
    email: `e2e-${Date.now()}-${randomBytes(4).toString("hex")}@example.test`,
    password: randomBytes(16).toString("hex"),
    handle: randomHandle(),
  };
  const response = await fetch(`${gatewayURL}/auth/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(credentials),
    signal: AbortSignal.timeout(5000),
  });
  if (response.status !== 201) {
    throw new Error(`register at the gateway answered ${response.status}`);
  }
  const { user_id: userId } = (await response.json()) as { user_id: string };
  return { ...credentials, userId };
}

// An access token of `account`, from a login at the gateway (not through the web, whose login bucket the browser tests
// share). Each user logs in at most a few times, under the login-email burst of 5.
export async function gatewayToken(account: Account): Promise<string> {
  const response = await fetch(`${gatewayURL}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: account.email, password: account.password }),
    signal: AbortSignal.timeout(5000),
  });
  if (response.status !== 200) {
    throw new Error(`login at the gateway answered ${response.status}`);
  }
  return ((await response.json()) as { access_token: string }).access_token;
}

async function gatewayJSON<T>(token: string, method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(`${gatewayURL}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    throw new Error(`${method} ${path} at the gateway answered ${response.status}`);
  }
  return (await response.json()) as T;
}

export type UploadForm = { video_id: string; upload_url: string; form_fields: Record<string, string> };

// POST /videos: a new video in UPLOADING with its presigned form. A video nobody uploads stays UPLOADING (until the
// upload cleanup turns it FAILED) and takes one of the user's 3 open uploads.
export function createVideo(token: string, title: string, sizeBytes: number): Promise<UploadForm> {
  return gatewayJSON(token, "POST", "/videos", { title, size_bytes: sizeBytes, content_type: "video/mp4" });
}

// Creates, uploads and completes a video of the file at `path` like upload_ready of e2e/seed.sh, then waits for READY.
export async function publishVideo(token: string, title: string, path: string): Promise<string> {
  const file = readFileSync(path);
  const form = await createVideo(token, title, file.length);
  const body = new FormData();
  for (const [name, value] of Object.entries(form.form_fields)) {
    body.append(name, value);
  }
  body.append("file", new Blob([file], { type: "video/mp4" }));
  const stored = await fetch(form.upload_url, { method: "POST", body, signal: AbortSignal.timeout(60_000) });
  if (!stored.ok) {
    throw new Error(`the storage answered ${stored.status} to the upload`);
  }
  await gatewayJSON(token, "POST", `/videos/${form.video_id}/complete`);
  await expect
    .poll(async () => (await gatewayJSON<{ status: string }>(token, "GET", `/videos/${form.video_id}`)).status, {
      timeout: 180_000,
      intervals: [1000],
    })
    .toBe("READY");
  return form.video_id;
}

// A READY video as anyone reads it: GET /public/videos/{id}, straight at the gateway, so from the public rate limit
// bucket of this machine, not the one of the web container that the browser tests share.
export async function publicVideo(
  videoId: string,
): Promise<{ title: string; playlist_url: string; thumbnail_url: string }> {
  const response = await fetch(`${gatewayURL}/public/videos/${videoId}`, { signal: AbortSignal.timeout(5000) });
  if (response.status !== 200) {
    throw new Error(`GET /public/videos/${videoId} at the gateway answered ${response.status}`);
  }
  return (await response.json()) as { title: string; playlist_url: string; thumbnail_url: string };
}

// UPLOAD_ORIGIN of the stack: the storage the browser sends files to (the object store's published port on compose, its
// route through Envoy on k3d).
export const uploadOrigin = stack.uploadOrigin;

// The URL of the presigned upload form: the uploads bucket, path-style. The media the pages play (MEDIA_ORIGIN) are on
// the same origin under /media, so a test that holds back uploads matches this URL, not the origin.
export const uploadURL = `${uploadOrigin}/uploads`;

// Records in the page, in order, each value the upload progress bar takes ("progress 42") and each alert shown ("alert
// <text>"), from now until the document goes away (the upload steps are one document). A step can last a few
// milliseconds over loopback, too short for Playwright to see by polling. The returned function reads the record.
export async function recordUploadScreen(page: Page): Promise<() => Promise<string[]>> {
  await page.evaluate(() => {
    const events: string[] = [];
    (window as unknown as { __svpUploadScreen: string[] }).__svpUploadScreen = events;
    let progress: string | null = null;
    let alert: string | null = null;
    new MutationObserver(() => {
      const value =
        document.querySelector('[role="progressbar"][aria-label="Upload progress"]')?.getAttribute("aria-valuenow") ??
        null;
      if (value !== null && value !== progress) {
        events.push(`progress ${value}`);
      }
      progress = value;
      // Not Next's route announcer, which is an alert too.
      const text = document.querySelector('[role="alert"]:not(#__next-route-announcer__)')?.textContent ?? null;
      if (text !== null && text !== alert) {
        events.push(`alert ${text}`);
      }
      alert = text;
    }).observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
  });
  return () => page.evaluate(() => [...(window as unknown as { __svpUploadScreen: string[] }).__svpUploadScreen]);
}

// The folder of web/test-results the e2e run writes its own files into (gitignored).
export const testResultsDir = join(import.meta.dirname, "..", "test-results");

// An H.264/AAC MP4 test clip (moving test pattern and a sine tone) of that length and size, made with ffmpeg exactly as
// make_video of deploy/compose/lib.sh, under test-results/clips. Kept between runs: the same arguments make the same
// clip, and a 60 s 1080p one takes a while to encode.
export function testClip(seconds: number, size: string): string {
  const dir = join(testResultsDir, "clips");
  const path = join(dir, `clip-${seconds}s-${size}.mp4`);
  if (!existsSync(path)) {
    mkdirSync(dir, { recursive: true });
    const partial = `${path}.partial.mp4`;
    execFileSync(
      "ffmpeg",
      [
        ...["-nostdin", "-hide_banner", "-loglevel", "error", "-y"],
        ...["-f", "lavfi", "-i", `testsrc2=size=${size}:rate=30:duration=${seconds}`],
        ...["-f", "lavfi", "-i", `sine=frequency=440:sample_rate=48000:duration=${seconds}`],
        ...["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k"],
        ...["-shortest", "-movflags", "+faststart", partial],
      ],
      { stdio: ["ignore", "inherit", "inherit"] },
    );
    renameSync(partial, path);
  }
  return path;
}

// Fills and sends the form of the login page at `path` (which may carry `next`).
export async function logIn(page: Page, account: Credentials, path = "/login"): Promise<void> {
  await page.goto(path);
  await fillAuthForm(page, account);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
}

export async function fillAuthForm(page: Page, account: Credentials): Promise<void> {
  await page.getByLabel("Email").fill(account.email);
  // Exact: the eye button next to the field is labelled "Show password".
  await page.getByLabel("Password", { exact: true }).fill(account.password);
}

// The shell has a logout button in the desktop sidebar and one in the bottom bar; only one of them shows.
export async function logOut(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Log out" }).filter({ visible: true }).click();
}

// Item `index` of the vertical feed (features/feed/feed-screen.tsx); the one after the last video is the tail.
export function feedItem(page: Page, index: number): Locator {
  return page.locator(`[role="feed"] > article[data-index="${index}"]`);
}

// The player marks the <video> it moved into an item with data-state (features/feed/player-pool.ts).
export function playingVideo(item: Locator): Locator {
  return item.locator('video[data-state="playing"]');
}

type StorageState = Awaited<ReturnType<BrowserContext["storageState"]>>;

type WorkerFixtures = {
  // LOCAL LAB ONLY: before the first test of every worker (one per project, and a new one after a failed test), the
  // gateway's register rate limit keys (svp:gw:rl:register:*) in Redis db 10 on 127.0.0.1:6379 (on k3d: Valkey db 10
  // of cluster svp, through kubectl, as SVP_STACK=k3d tells lib.sh) are deleted with SCAN + DEL, by
  // reset_register_limit of deploy/compose/lib.sh as e2e/seed.sh and `make smoke` do; the limit itself is not raised.
  // Never point the e2e run at a shared stack.
  registerLimitReset: void;
  // A user of this worker, logged in once through the login page; its cookie is kept for the tests of `authedTest`.
  sessionAccount: Account & { storageState: StorageState };
};

type TestFixtures = {
  // Every Content-Security-Policy violation of the test's page: the event of the document and the console message
  // the browser logs. The test fails when there is any.
  cspViolations: string[];
};

export const test = base.extend<TestFixtures, WorkerFixtures>({
  cspViolations: [
    async ({ page }, provide) => {
      const violations: string[] = [];
      await page.exposeFunction("__svpCspViolation", (violation: string) => violations.push(violation));
      await page.addInitScript(() => {
        document.addEventListener("securitypolicyviolation", (event) => {
          const report = (window as unknown as { __svpCspViolation: (violation: string) => void }).__svpCspViolation;
          report(
            `${event.effectiveDirective} blocked ${event.blockedURI || "inline"} (${event.sourceFile}:${event.lineNumber})`,
          );
        });
      });
      page.on("console", (message) => {
        if (
          /content[- ]security[- ]policy|refused to (load|execute|apply|connect|frame|create)/i.test(message.text())
        ) {
          violations.push(`console: ${message.text()}`);
        }
      });
      await provide(violations);
      expect(violations, "Content-Security-Policy violations").toEqual([]);
    },
    { auto: true },
  ],
  registerLimitReset: [
    async ({}, provide) => {
      // Sourcing lib.sh runs reset_register_limit, which exits non-zero when redis-cli fails.
      const lib = join(import.meta.dirname, "..", "..", "deploy", "compose", "lib.sh");
      execFileSync("bash", ["-c", 'source "$1"', "bash", lib], { stdio: ["ignore", "inherit", "inherit"] });
      await provide();
    },
    // Auto worker fixtures are set up before the others, so before sessionAccount registers.
    { scope: "worker", auto: true },
  ],
  sessionAccount: [
    async ({ browser }, provide, workerInfo) => {
      const account = await registerAccount();
      const { baseURL, locale } = workerInfo.project.use;
      const context = await browser.newContext({ baseURL, locale, ...stack.contextOptions });
      const page = await context.newPage();
      await logIn(page, account);
      await page.waitForURL("/");
      const storageState = await context.storageState();
      await context.close();
      await provide({ ...account, storageState });
    },
    { scope: "worker" },
  ],
});

// Tests that start logged in as the worker's sessionAccount. They must not log it out: the others share its session.
export const authedTest = test.extend({
  storageState: async ({ sessionAccount }, provide) => provide(sessionAccount.storageState),
});

export { expect };
