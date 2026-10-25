import type { Page, Response } from "@playwright/test";
import { authedTest, expect, feedItem, logIn, playingVideo, registerAccount, test } from "./fixtures";

// Feed behaviour that needs a real browser layout (scroll snap, IntersectionObserver, router cache): the item after
// the last video while the next page loads, and like state across browser Back (features/feed/feed-screen.tsx,
// features/feed/use-feed.ts).

// The explore feed's requests for a page after the first.
function isNextPageRequest(url: URL): boolean {
  return url.pathname === "/api/feed/explore" && url.searchParams.has("cursor");
}

async function scrollTo(page: Page, index: number): Promise<void> {
  await feedItem(page, index).evaluate((item) => item.scrollIntoView({ block: "start", behavior: "instant" }));
}

authedTest(
  "sitting on the loading item while the next page loads: its first video plays, no page after it loads",
  async ({ page }) => {
    test.slow();
    let nextPageRequests = 0;
    let release = () => {};
    const held = new Promise<void>((resolve) => (release = resolve));
    await page.route(isNextPageRequest, async (route) => {
      nextPageRequests += 1;
      await held;
      await route.continue();
    });

    await page.goto("/");
    await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);
    const pageSize = await page.locator('[role="feed"] > article [data-part="video-host"]').count();
    expect(pageSize).toBeGreaterThan(2);

    // One of the last two videos asks for the next page, which the route holds.
    await scrollTo(page, pageSize - 2);
    await expect.poll(() => nextPageRequests).toBe(1);

    // The item after the last video shows the page loading and becomes the current one.
    const tail = feedItem(page, pageSize);
    await scrollTo(page, pageSize);
    await expect(tail.locator('[data-part="video-host"]')).toHaveCount(0);
    await expect(page.locator('[role="feed"]')).toHaveAttribute("aria-busy", "true");
    await page.waitForTimeout(500);

    release();
    // The page arrives: the first new video takes the tail's place, is on screen and plays; no end screen.
    const firstNew = feedItem(page, pageSize);
    await expect(firstNew.locator('[data-part="video-host"]')).toHaveCount(1);
    await expect(playingVideo(firstNew)).toHaveCount(1);
    await expect(firstNew).toBeInViewport({ ratio: 0.6 });
    await expect(page.getByText("You're all caught up")).toHaveCount(0);
    // It is not one of the last two videos, so no further page is asked for.
    await page.waitForTimeout(2000);
    expect(nextPageRequests).toBe(1);
  },
);

// hls.js's ES module build carries no inlined transmuxer worker: the player pool gives it the worker file the build
// serves, so segments are transmuxed off the main thread instead of one long task each (features/feed/player-pool.ts).
authedTest("the first video plays with hls.js's transmuxer in a worker loaded from its own file", async ({ page }) => {
  const workers: string[] = [];
  page.on("worker", (worker) => workers.push(new URL(worker.url()).pathname));
  await page.goto("/");
  await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);
  await expect
    .poll(() => workers.filter((path) => /^\/_next\/static\/media\/hls\.worker\.[\w-]+\.js$/.test(path)).length)
    .toBeGreaterThan(0);
});

// The next item's poster sits inside the browser's lazy-load margin, so it would download beside the current poster,
// the page's largest paint. The next item gets it two ways, each held back: its <img> renders only after the window's
// load event, which waits for the current poster; the player's <video> for it, which carries the same poster, waits for
// the current video to play (features/feed/player-pool.ts). The routes hold every poster and playlist so the test fixes
// the order of the two, and it reads the page rather than resource timing: an image the <video> fetched first is
// reused by the <img> without an entry of its own.
authedTest(
  "the next item's poster waits for the current video to play, its image for the load event",
  async ({ page }) => {
    const posters: string[] = [];
    let releasePlaylists = () => {};
    const playlistsHeld = new Promise<void>((resolve) => (releasePlaylists = resolve));
    let releasePosters = () => {};
    const postersHeld = new Promise<void>((resolve) => (releasePosters = resolve));
    await page.route(
      (url) => url.pathname.endsWith(".m3u8"),
      async (route) => {
        await playlistsHeld;
        await route.continue();
      },
    );
    await page.route(
      (url) => url.pathname.endsWith("/thumbnail.jpg"),
      async (route) => {
        posters.push(route.request().url());
        await postersHeld;
        await route.continue();
      },
    );

    // The held poster keeps the load event from firing: the navigation waits for the document only.
    await page.goto("/", { waitUntil: "domcontentloaded" });
    const src = await feedItem(page, 0).locator("img").getAttribute("src");
    expect(src).toBeTruthy();
    const current = new URL(src ?? "").href;
    // Hydrated: the player moved a <video> into the current item. Its playlist is held, so it cannot play, and nothing
    // has asked for another poster.
    await expect(feedItem(page, 0).locator("video")).toHaveCount(1);
    await expect.poll(() => posters.includes(current), { message: "the current poster's request" }).toBe(true);
    await expect(feedItem(page, 1).locator("video")).toHaveCount(0);
    await expect(feedItem(page, 1).locator("img")).toHaveCount(0);
    expect(new Set(posters)).toEqual(new Set([current]));

    // The current video plays while its poster is still held: the player gives the next item its <video>, and the next
    // item's <img> still waits for the load event.
    releasePlaylists();
    await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);
    await expect(feedItem(page, 1).locator("video")).toHaveCount(1);
    expect(await page.evaluate(() => document.readyState)).not.toBe("complete");
    await expect(feedItem(page, 1).locator("img")).toHaveCount(0);

    // The current poster arrives, the page loads, and the next item's <img> follows.
    releasePosters();
    await expect(feedItem(page, 1).locator("img")).toHaveAttribute("src", /\/thumbnail\.jpg$/);
  },
);

// Logs a fresh user in, likes the first video of Explore and opens Following; returns when Explore rendered (ms since
// the epoch, taken as the page showed, so the server rendered it a little earlier).
async function likeThenOpenFollowing(page: Page): Promise<number> {
  await logIn(page, await registerAccount());
  await expect(page).toHaveURL("/");
  const renderedAt = Date.now();
  const first = feedItem(page, 0);
  await first.getByRole("button", { name: /^Like video/, pressed: false }).click();
  await expect(first.getByRole("button", { name: /^Like video/, pressed: true })).toBeVisible();
  await page.getByRole("tab", { name: "Following" }).click();
  await expect(page).toHaveURL("/following");
  return renderedAt;
}

function isFirstPageResponse(response: Response): boolean {
  const url = new URL(response.url());
  return url.pathname === "/api/feed/explore" && !isNextPageRequest(url);
}

test("Back to Explore more than 5 s after it rendered: the video liked there shows liked", async ({ page }) => {
  test.slow();
  const renderedAt = await likeThenOpenFollowing(page);
  await page.waitForTimeout(Math.max(0, renderedAt + 5500 - Date.now()));
  const refetched = page.waitForResponse(isFirstPageResponse);
  await page.goBack();
  await expect(page).toHaveURL("/");
  // The router replays the page of the first visit, which this tab has shown already: the first page is fetched again
  // in the background.
  expect((await refetched).status()).toBe(200);
  await expect(feedItem(page, 0).getByRole("button", { name: /^Like video/, pressed: true })).toBeVisible();
});

// Without any wait: a replayed page is told apart from a new one by its stamp alone, never by its age on a clock.
test("Back to Explore right after a like there: the video shows liked", async ({ page }) => {
  await likeThenOpenFollowing(page);
  const refetched = page.waitForResponse(isFirstPageResponse);
  await page.goBack();
  await expect(page).toHaveURL("/");
  expect((await refetched).status()).toBe(200);
  await expect(feedItem(page, 0).getByRole("button", { name: /^Like video/, pressed: true })).toBeVisible();
});
