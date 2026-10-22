import { randomBytes } from "node:crypto";
import {
  expect,
  feedItem,
  fillAuthForm,
  generatedHandle,
  logIn,
  logOut,
  playingVideo,
  randomHandle,
  test,
} from "./fixtures";
import { seed } from "./seed";

// The main flow in one browser session: register with a handle (which logs in), watch explore, like, follow, find the
// video in Following, log out, log in again through the form.
test("register, watch, like, follow, Following, log out and log in again", async ({ page }) => {
  const { xss } = seed();
  const account = {
    email: `e2e-flow-${Date.now()}-${randomBytes(4).toString("hex")}@example.test`,
    password: randomBytes(16).toString("hex"),
  };

  await page.goto("/register");
  await fillAuthForm(page, account);
  await page.getByLabel("Username").fill(randomHandle());
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page).toHaveURL("/");

  // The shell links to Upload and the profile.
  const nav = page.getByRole("navigation", { name: "Main navigation" });
  await expect(nav.getByRole("link", { name: "Profile" })).toHaveAttribute("href", "/me");
  await expect(page.getByRole("link", { name: "Upload" }).filter({ visible: true })).toHaveAttribute("href", "/upload");

  // The seeded video leads explore and plays (muted autoplay; nothing here depends on sound), with its author's name and
  // @handle (the seeded author has the generated handle, which is also its display name) and a share button.
  const first = feedItem(page, 0);
  await expect(first).toHaveAttribute("aria-label", xss.title);
  await expect(playingVideo(first)).toHaveCount(1);
  const handle = generatedHandle(xss.author_id);
  await expect(first.getByRole("link", { name: handle, exact: true })).toHaveAttribute("href", `/u/${handle}`);
  await expect(first.getByText(`@${handle}`)).toBeVisible();
  await expect(first.getByRole("button", { name: "Copy share link" })).toBeVisible();

  // Like: the button keeps its name, turns pressed, and the count, when the feed carries one, goes up by one; a reload
  // keeps both.
  const like = first.getByRole("button", { name: /^Like video/ });
  await expect(like).toHaveAttribute("aria-pressed", "false");
  const before = Number(await like.innerText());
  await like.click();
  const liked = first.getByRole("button", { name: /^Like video/, pressed: true });
  await expect(liked).toBeVisible();
  if (Number.isInteger(before)) {
    await expect(liked).toHaveText(String(before + 1));
  }
  await page.reload();
  await expect(feedItem(page, 0).getByRole("button", { name: /^Like video/, pressed: true })).toBeVisible();

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
