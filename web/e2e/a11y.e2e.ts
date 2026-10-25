import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { authedTest, expect, feedItem, generatedHandle, playingVideo, test } from "./fixtures";
import { seed } from "./seed";

// axe on the screens of the web client: no violation of impact serious or critical.
// The cspViolations fixture fails each test on any CSP violation as well, so these pages are also the
// "no CSP violation" check of login, register, the feed while a video plays, upload, the profiles and the share page.

async function expectNoSeriousViolations(page: Page): Promise<void> {
  const { violations } = await new AxeBuilder({ page }).analyze();
  const serious = violations
    .filter((violation) => violation.impact === "serious" || violation.impact === "critical")
    .map((violation) => `${violation.impact} ${violation.id}: ${violation.help} (${violation.nodes.length} nodes)`);
  expect(serious).toEqual([]);
}

for (const path of ["/login", "/register"]) {
  test(`${path}: no serious accessibility violation, no CSP violation`, async ({ page }) => {
    await page.goto(path);
    await page.waitForLoadState("networkidle");
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expectNoSeriousViolations(page);
  });
}

authedTest("feed while a video plays: no serious accessibility violation, no CSP violation", async ({ page }) => {
  await page.goto("/");
  await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);
  await expectNoSeriousViolations(page);
});

authedTest("/upload, /me and /u/{handle}: no serious accessibility violation, no CSP violation", async ({ page }) => {
  await page.goto("/upload");
  await expect(page.getByRole("button", { name: "Choose file" })).toBeVisible();
  await expectNoSeriousViolations(page);

  await page.goto("/me");
  await expect(page.getByRole("heading", { level: 1 })).toBeAttached();
  await page.waitForLoadState("networkidle");
  await expectNoSeriousViolations(page);

  const { xss } = seed();
  await page.goto(`/u/${generatedHandle(xss.author_id)}`);
  await expect(page.getByRole("button", { name: /^Follow/ })).toBeVisible();
  await expectNoSeriousViolations(page);
});

test("/v/{id} for a guest while the video plays: no serious accessibility violation, no CSP violation", async ({
  page,
}) => {
  const { xss } = seed();
  await page.goto(`/v/${xss.video_id}`);
  await expect(playingVideo(page.locator("article"))).toHaveCount(1);
  await expectNoSeriousViolations(page);
});
