import { randomUUID } from "node:crypto";
import {
  createVideo,
  expect,
  gatewayToken,
  generatedHandle,
  playingVideo,
  publicVideo,
  registerAccount,
  test,
} from "./fixtures";
import { seed } from "./seed";
import { stack } from "./stack";

// The public share page /v/{id}, seen by someone who is
// not logged in: Playwright's `request` and a new browser context start without any cookie. Every guest page load
// goes through the web container to the gateway's public rate limit bucket (120 a minute, burst 60, shared by all the
// browsers of the run), so these tests load few pages.

// APP_ORIGIN of the web, which its share links and Open Graph URLs name.
const appOrigin = stack.appOrigin;

// The attributes of every <meta> tag of an HTML document, values unescaped as a browser reads them.
function metaTags(html: string): Record<string, string>[] {
  const unescape = (value: string) =>
    value
      .replaceAll("&lt;", "<")
      .replaceAll("&gt;", ">")
      .replaceAll("&quot;", '"')
      .replaceAll("&#x27;", "'")
      .replaceAll("&#39;", "'")
      .replaceAll("&amp;", "&");
  return (html.match(/<meta\b[^>]*>/g) ?? []).map((tag) =>
    Object.fromEntries([...tag.matchAll(/([a-z:-]+)="([^"]*)"/g)].map(([, name, value]) => [name, unescape(value!)])),
  );
}

function metaContent(html: string, key: string): string[] {
  return metaTags(html)
    .filter((tag) => tag.property === key || tag.name === key)
    .map((tag) => tag.content ?? "");
}

test("a guest watches a READY video on /v/{id}, with the author's name and @handle, and gets no cookie", async ({
  browser,
}) => {
  const { xss } = seed();
  const handle = generatedHandle(xss.author_id);
  const context = await browser.newContext({ baseURL: appOrigin, locale: "en-US", ...stack.contextOptions });
  try {
    const page = await context.newPage();
    const response = await page.goto(`/v/${xss.video_id}`);
    expect(response?.status()).toBe(200);
    await expect(playingVideo(page.locator("article"))).toHaveCount(1);
    // The seeded author has no display name of its own: it is the generated handle.
    await expect(page.getByText(`@${handle}`).filter({ visible: true }).first()).toBeVisible();
    await expect(page.getByText(handle, { exact: true }).filter({ visible: true }).first()).toBeVisible();
    // A guest gets login and register links, and the page set no cookie (no session was made for them).
    await expect(page.getByRole("link", { name: "Log in" }).first()).toBeVisible();
    expect(await response?.headerValue("set-cookie")).toBeNull();
    expect(await context.cookies()).toEqual([]);
  } finally {
    await context.close();
  }
});

test("the raw HTML of /v/{id} without a cookie has the Open Graph tags of the video", async ({ request }) => {
  const { xss } = seed();
  const video = await publicVideo(xss.video_id);
  const response = await request.get(`/v/${xss.video_id}`);
  expect(response.status()).toBe(200);
  expect(response.headers()["set-cookie"]).toBeUndefined();
  const html = await response.text();

  expect(metaContent(html, "og:title")).toEqual([xss.title]);
  expect(metaContent(html, "og:type")).toEqual(["video.other"]);
  expect(metaContent(html, "og:url")).toEqual([`${appOrigin}/v/${xss.video_id}`]);
  expect(metaContent(html, "og:image")).toEqual([video.thumbnail_url]);
  expect(metaContent(html, "og:video")).toEqual([video.playlist_url]);
  expect(metaContent(html, "og:video:type")).toEqual(["application/vnd.apple.mpegurl"]);
  const handle = generatedHandle(xss.author_id);
  expect(metaContent(html, "og:description")).toEqual([`${handle} (@${handle})`]);
  expect(metaContent(html, "twitter:card")).toEqual(["summary_large_image"]);
});

test("WEB-1: the HTML title of the seeded video is escaped in the page and in its meta tags", async ({
  page,
  request,
}) => {
  const { xss } = seed();
  const html = await (await request.get(`/v/${xss.video_id}`)).text();
  const escaped = "&lt;img src=x onerror=window.__xss=1&gt;";
  expect(html).toContain(`<title>${escaped}</title>`);
  expect(html).toContain(`property="og:title" content="${escaped}"`);
  expect(html).not.toContain("<img src=x");

  await page.goto(`/v/${xss.video_id}`);
  await expect(page.getByRole("heading", { level: 1, name: xss.title })).toBeVisible();
  await expect(page).toHaveTitle(xss.title);
  // Hydrated and playing: an onerror handler of a real <img src=x> would have run by now.
  await expect(playingVideo(page.locator("article"))).toHaveCount(1);
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  expect(await page.evaluate(() => "__xss" in window)).toBe(false);
});

test("M39: a random id and a video that is not READY are both the same 404", async ({ page, request }) => {
  // An id no video has.
  const missing = await page.goto(`/v/${randomUUID()}`);
  expect(missing?.status()).toBe(404);
  await expect(page.getByRole("heading", { level: 1, name: "Video not found" })).toBeVisible();

  // A video in UPLOADING: nobody but its author may see it, and not here either.
  const author = await registerAccount();
  const { video_id: uploading } = await createVideo(await gatewayToken(author), "e2e never uploaded", 1024);
  const notReady = await page.goto(`/v/${uploading}`);
  expect(notReady?.status()).toBe(404);
  await expect(page.getByRole("heading", { level: 1, name: "Video not found" })).toBeVisible();

  // Not a UUID: the 404 comes without a call to the gateway.
  expect((await request.get("/v/not-a-video")).status()).toBe(404);
});

test("a guest pressing like is asked to log in, back to the video afterwards", async ({ page }) => {
  const { xss } = seed();
  await page.goto(`/v/${xss.video_id}`);
  await expect(playingVideo(page.locator("article"))).toHaveCount(1);
  // The side panel's like button (wide screen); the one over the video does the same.
  await page.getByRole("button", { name: "Like", exact: true }).click();
  const prompt = page.getByRole("dialog", { name: "Log in to like videos" });
  await expect(prompt).toBeVisible();
  const next = `/login?next=${encodeURIComponent(`/v/${xss.video_id}`)}`;
  await expect(prompt.getByRole("link", { name: "Log in" })).toHaveAttribute("href", next);
  await prompt.getByRole("link", { name: "Log in" }).click();
  await expect(page).toHaveURL(next);
});
