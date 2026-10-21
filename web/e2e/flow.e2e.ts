import { randomBytes } from "node:crypto";
import { expect, feedItem, fillAuthForm, logIn, logOut, playingVideo, test } from "./fixtures";
import { seed } from "./seed";

// The main flow of part A in one browser session: register (which logs in), watch explore, like, follow, find the
// video in Following, log out, log in again through the form.
test("register, watch, like, follow, Following, log out and log in again", async ({ page }) => {
  const { xss } = seed();
  const account = {
    email: `e2e-flow-${Date.now()}-${randomBytes(4).toString("hex")}@example.test`,
    password: randomBytes(16).toString("hex"),
  };

  await page.goto("/register");
  await fillAuthForm(page, account);
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page).toHaveURL("/");

  // The seeded video leads explore and plays (muted autoplay; nothing here depends on sound).
  const first = feedItem(page, 0);
  await expect(first).toHaveAttribute("aria-label", xss.title);
  await expect(playingVideo(first)).toHaveCount(1);

  // Like: the button turns pressed and the count, when the feed carries one, goes up by one; a reload keeps both.
  const like = first.getByRole("button", { name: "Like video" });
  const before = Number(await like.innerText());
  await like.click();
  const unlike = first.getByRole("button", { name: "Unlike video" });
  await expect(unlike).toHaveAttribute("aria-pressed", "true");
  if (Number.isInteger(before)) {
    await expect(unlike).toHaveText(String(before + 1));
  }
  await page.reload();
  await expect(feedItem(page, 0).getByRole("button", { name: "Unlike video" })).toHaveAttribute("aria-pressed", "true");

  // Follow the author: their only video reaches Following (feed-service backfills it asynchronously).
  await feedItem(page, 0).getByRole("button", { name: "Follow creator" }).click();
  await expect(feedItem(page, 0).getByRole("button", { name: "Unfollow creator" })).toBeVisible();
  await page.getByRole("tab", { name: "Following" }).click();
  await expect(page).toHaveURL("/following");
  await expect(async () => {
    await page.reload();
    await expect(feedItem(page, 0)).toHaveAttribute("aria-label", xss.title, { timeout: 2000 });
  }).toPass({ timeout: 30_000 });
  // Nothing else: the item after it is the end of the feed.
  await expect(feedItem(page, 1).locator('[data-part="video-host"]')).toHaveCount(0);
  await expect(page.getByText("You're all caught up")).toBeVisible();
  await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);

  await logOut(page);
  await expect(page).toHaveURL("/login");
  await page.goto("/");
  await expect(page).toHaveURL(/\/login\?next=/);

  await logIn(page, account);
  await expect(page).toHaveURL("/");
  await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);
});
