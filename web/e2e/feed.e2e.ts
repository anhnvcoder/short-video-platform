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

// Logs a fresh user in, likes the first video of Explore and opens Following; returns when Explore rendered (ms since
// the epoch, taken as the page showed, so the server rendered it a little earlier).
async function likeThenOpenFollowing(page: Page): Promise<number> {
  await logIn(page, await registerAccount());
  await expect(page).toHaveURL("/");
  const renderedAt = Date.now();
  const first = feedItem(page, 0);
  await first.getByRole("button", { name: "Like video" }).click();
  await expect(first.getByRole("button", { name: "Unlike video" })).toHaveAttribute("aria-pressed", "true");
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
  await expect(feedItem(page, 0).getByRole("button", { name: "Unlike video" })).toHaveAttribute("aria-pressed", "true");
});

// Without any wait: a replayed page is told apart from a new one by its stamp alone, never by its age on a clock.
test("Back to Explore right after a like there: the video shows liked", async ({ page }) => {
  await likeThenOpenFollowing(page);
  const refetched = page.waitForResponse(isFirstPageResponse);
  await page.goBack();
  await expect(page).toHaveURL("/");
  expect((await refetched).status()).toBe(200);
  await expect(feedItem(page, 0).getByRole("button", { name: "Unlike video" })).toHaveAttribute("aria-pressed", "true");
});
