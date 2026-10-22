import { randomBytes } from "node:crypto";
import { basename } from "node:path";
import type { BrowserContext, Page, Route } from "@playwright/test";
import {
  expect,
  logIn,
  playingVideo,
  recordUploadScreen,
  registerAccount,
  test,
  testClip,
  uploadURL,
} from "./fixtures";

// Upload from the browser (docs/adr/0018-web-profiles-public-video-upload.md, section 8): a 60 s 1080p clip goes from
// /upload to the storage with a presigned POST, the worker transcodes it to READY, and the video plays on its share
// page. Each test has a user of its own: a user has at most 3 open uploads in 15 minutes, and the interrupted upload
// may open more than one. Tagged @publishes: a READY video leads Explore, so these run after the other tests of both
// browsers (playwright.config.ts).

// The worker transcodes a 60 s 1080p clip in about 50 s (make measure-ready); the rest is margin for a queue.
const readyTimeout = 240_000;

async function openUpload(page: Page): Promise<void> {
  await logIn(page, await registerAccount());
  await expect(page).toHaveURL("/");
  await page.goto("/upload");
  await expect(page.getByRole("heading", { level: 1, name: "Upload a video" })).toBeVisible();
}

// Picks the clip, gives it a title and posts it.
async function postClip(page: Page, clip: string): Promise<string> {
  // The drop zone's file input is hidden behind its button; Playwright sets files on hidden inputs as well.
  await page.locator('input[type="file"]').setInputFiles(clip);
  await expect(page.getByText(basename(clip))).toBeVisible();
  const title = `e2e upload ${randomBytes(4).toString("hex")}`;
  await page.getByLabel("Title").fill(title);
  await page.getByRole("button", { name: "Post video" }).click();
  return title;
}

// READY on the result step, then the share page of the video plays it.
async function watchWhenReady(page: Page, title: string): Promise<void> {
  await expect(page.getByText("Processing the video")).toBeVisible();
  await expect(page.getByText("Your video is ready")).toBeVisible({ timeout: readyTimeout });
  await page.getByRole("link", { name: "Watch video" }).click();
  await expect(page).toHaveURL(/^http:\/\/localhost:3001\/v\/[0-9a-f-]{36}$/);
  await expect(page.getByRole("heading", { level: 1, name: title })).toBeVisible();
  await expect(playingVideo(page.locator("article"))).toHaveCount(1);
}

test("upload a 60 s 1080p clip: progress, processing, READY, and it plays", { tag: "@publishes" }, async ({ page }) => {
  test.setTimeout(readyTimeout + 60_000);
  const clip = testClip(60, "1920x1080");
  await openUpload(page);
  const screen = await recordUploadScreen(page);
  const title = await postClip(page, clip);
  await watchWhenReady(page, title);

  // The bar moved through the upload, not straight from nothing to done: over loopback the whole file takes well under
  // a second, too short to watch from here, so the page recorded every value.
  const values = (await screen()).flatMap((event) => (event.startsWith("progress ") ? [Number(event.slice(9))] : []));
  expect(
    values.some((value) => value > 0 && value < 100),
    `progress values ${values.join(", ")}`,
  ).toBe(true);
  expect(values.at(-1)).toBe(100);
});

// Breaks the first POST of the file to the storage and takes the browser offline in the same step, as a lost
// connection does; later POSTs go through. Playwright cannot break a request already on its way in either browser,
// and context.setOffline() only stops new requests (an upload in flight still finishes), so:
// - Chromium: the DevTools Fetch domain pauses the POST once the storage has answered, after the whole body went out,
//   and fails it with InternetDisconnected: the page saw the upload's progress, then a network error.
// - WebKit, which has no such hook: page.route aborts the POST with internetdisconnected before any byte leaves.
// Returns how many POSTs reached the cut so far.
async function cutFirstUpload(page: Page, context: BrowserContext, browserName: string): Promise<() => number> {
  let posts = 0;
  if (browserName === "chromium") {
    const cdp = await context.newCDPSession(page);
    cdp.on("Fetch.requestPaused", (event) => {
      (async () => {
        if (event.request.method === "POST" && ++posts === 1) {
          await context.setOffline(true);
          await cdp.send("Fetch.failRequest", { requestId: event.requestId, errorReason: "InternetDisconnected" });
        } else {
          await cdp.send("Fetch.continueResponse", { requestId: event.requestId });
        }
      })().catch(() => {
        // The request was cancelled, or the page closed at the end of the test, before the command reached it: there
        // is nothing left to fail or continue. A cut that did not happen fails the checks of the test itself.
      });
    });
    // Only the upload form's URL: the playlists, segments and thumbnails the share page loads afterwards are on the
    // same origin and must not wait on this session.
    await cdp.send("Fetch.enable", { patterns: [{ urlPattern: `${uploadURL}*`, requestStage: "Response" }] });
  } else {
    await page.route(`${uploadURL}*`, async (route: Route) => {
      if (route.request().method() === "POST" && ++posts === 1) {
        await context.setOffline(true);
        await route.abort("internetdisconnected");
      } else {
        await route.continue();
      }
    });
  }
  return () => posts;
}

test(
  "the connection drops during the upload: the page retries by itself, then the video gets READY",
  { tag: "@publishes" },
  async ({ page, context, browserName }) => {
    test.setTimeout(readyTimeout + 60_000);
    const clip = testClip(60, "1920x1080");
    await openUpload(page);
    const posts = await cutFirstUpload(page, context, browserName);
    const screen = await recordUploadScreen(page);
    const title = await postClip(page, clip);

    // M29, the retry with its attempt count, then the wait for a connection (navigator.onLine is false).
    // Scoped: Next's route announcer is an alert too.
    await expect(page.getByRole("region", { name: "Upload a video" }).getByRole("alert")).toContainText(
      "Connection lost",
    );
    const events = await screen();
    const retrying = events.findIndex((event) => event.startsWith("alert Upload interrupted"));
    expect(retrying, `screen events ${events.join(" | ")}`).toBeGreaterThanOrEqual(0);
    expect(events[retrying]).toContain("attempt 1/3");
    if (browserName === "chromium") {
      // The cut came after the page reported progress.
      const before = events.slice(0, retrying).filter((event) => event.startsWith("progress "));
      expect(
        before.some((event) => Number(event.slice(9)) > 0),
        `screen events ${events.join(" | ")}`,
      ).toBe(true);
    }
    expect(posts()).toBe(1);

    // Back online: the same form is sent again, from the start.
    await context.setOffline(false);
    await watchWhenReady(page, title);
    expect(posts()).toBe(2);
  },
);
