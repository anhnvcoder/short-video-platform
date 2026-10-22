import { randomBytes } from "node:crypto";
import {
  authedTest,
  createVideo,
  expect,
  feedItem,
  gatewayToken,
  generatedHandle,
  logIn,
  publishVideo,
  registerAccount,
  test,
  testClip,
} from "./fixtures";
import { seed } from "./seed";

// Profiles (docs/adr/0018-web-profiles-public-video-upload.md, section 7): "My videos" at /me with every video of the
// user and its status, the display name changed there, another user's profile at /u/{handle} with its follow button.

test("/me lists my videos with their status, under my name and @handle", async ({ page }) => {
  const account = await registerAccount();
  // Created and never uploaded: it stays UPLOADING, which only its author sees.
  const title = `e2e not uploaded ${randomBytes(4).toString("hex")}`;
  await createVideo(await gatewayToken(account), title, 1024);

  await logIn(page, account, "/login?next=%2Fme");
  await expect(page).toHaveURL("/me");
  // A display name nobody set is the handle. The side bar shows the account too.
  await expect(page.getByText(`@${account.handle}`).filter({ visible: true }).first()).toBeVisible();
  const row = page.getByRole("listitem").filter({ hasText: title });
  await expect(row).toBeVisible();
  await expect(row.getByText("Uploading").filter({ visible: true })).toBeVisible();
});

authedTest("/u/{handle} of another user: Follow, still Following after a reload, then unfollow", async ({ page }) => {
  const { xss } = seed();
  const handle = generatedHandle(xss.author_id);
  await page.goto(`/u/${handle}`);
  await expect(page.getByText(`@${handle}`).filter({ visible: true }).first()).toBeVisible();
  // The seeded author's only video is in the grid.
  await expect(page.getByRole("link", { name: xss.title })).toHaveAttribute("href", `/v/${xss.video_id}`);

  const follow = page.getByRole("button", { name: "Follow", exact: true });
  await expect(follow).toHaveAttribute("aria-pressed", "false");
  await follow.click();
  const following = page.getByRole("button", { name: "Following", exact: true });
  await expect(following).toHaveAttribute("aria-pressed", "true");

  // followed_by_me of the gateway, not state kept in the page.
  await page.reload();
  await expect(following).toHaveAttribute("aria-pressed", "true");
  await following.click();
  await expect(follow).toHaveAttribute("aria-pressed", "false");
  await page.reload();
  await expect(follow).toHaveAttribute("aria-pressed", "false");
});

authedTest(
  "/u/{my handle} goes to /me, and an upper-case handle to its lower-case form",
  async ({ page, sessionAccount }) => {
    await page.goto(`/u/${sessionAccount.handle}`);
    await expect(page).toHaveURL("/me");

    const { xss } = seed();
    const handle = generatedHandle(xss.author_id);
    await page.goto(`/u/${handle.toUpperCase()}`);
    await expect(page).toHaveURL(`/u/${handle}`);
  },
);

// Tagged @publishes: the user's own READY video has to lead Explore for its new name to show there.
test(
  "a new display name with HTML in it shows as text on /me and in the feed",
  { tag: "@publishes" },
  async ({ page }) => {
    test.slow();
    const account = await registerAccount();
    const title = `e2e renamed author ${randomBytes(4).toString("hex")}`;
    // A short small clip: it transcodes in seconds.
    await publishVideo(await gatewayToken(account), title, testClip(4, "360x640"));

    await logIn(page, account, "/login?next=%2Fme");
    await expect(page).toHaveURL("/me");
    const name = "<img src=x onerror=window.__xss=1> e2e";
    await page.getByText("Change display name").click();
    await page.getByLabel("Display name").fill(name);
    await page.getByRole("button", { name: "Save name" }).click();
    await expect(page.getByText("Display name changed.")).toBeVisible();
    await expect(page.getByText(name, { exact: true }).filter({ visible: true }).first()).toBeVisible();

    // Explore's first page is cached for a few seconds (feed-service): reload until the new video leads it.
    await page.goto("/");
    await expect(async () => {
      await page.reload();
      await expect(feedItem(page, 0)).toHaveAttribute("aria-label", title, { timeout: 2000 });
    }).toPass({ timeout: 30_000 });
    await expect(feedItem(page, 0).getByRole("link", { name, exact: true })).toHaveAttribute(
      "href",
      `/u/${account.handle}`,
    );
    await expect(page.locator('img[src="x"]')).toHaveCount(0);
    expect(await page.evaluate(() => "__xss" in window)).toBe(false);
  },
);
