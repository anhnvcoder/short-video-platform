import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { authedTest, expect, feedItem, playingVideo, test } from "./fixtures";

// axe on the three screens of part A: no violation of impact serious or critical (docs/adr/0016-web-client.md,
// section 11). The cspViolations fixture fails each test on any CSP violation as well, so these pages are also the
// "no CSP violation" check of login, register and the feed while a video plays.

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
