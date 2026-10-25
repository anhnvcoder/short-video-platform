import { randomBytes } from "node:crypto";
import type { APIResponse } from "@playwright/test";
import {
  authedTest,
  expect,
  feedItem,
  logIn,
  logOut,
  playingVideo,
  registerAccount,
  test,
  uploadOrigin,
} from "./fixtures";
import { seed } from "./seed";
import { stack } from "./stack";

// The web rows of the threat model checked in a browser (docs/threat-model.md, section 4.9): WEB-1, WEB-2, WEB-4,
// WEB-6, WEB-10, and the Content-Security-Policy (a script nonce new on every response, connect-src of /upload).

// Compose serves plain http on localhost: the session cookie has no prefix and no Secure. On k3d,
// over https, it is __Host-Http-svp_sid with Secure (e2e/stack.ts).
const sessionCookie = stack.sessionCookie;

authedTest("WEB-1: an HTML title renders as text and runs nothing", async ({ page }) => {
  const { xss } = seed();

  // The server's HTML carries the title escaped, never as a tag.
  const html = await (await page.request.get("/")).text();
  expect(html).toContain("&lt;img src=x onerror=window.__xss=1&gt;");
  expect(html).not.toContain("<img src=x");

  await page.goto("/");
  const item = feedItem(page, 0);
  await expect(item).toHaveAttribute("aria-label", xss.title);
  await expect(item.getByText(xss.title, { exact: true })).toBeVisible();
  // Hydrated and playing: an onerror handler of a real <img src=x> would have run by now.
  await expect(playingVideo(item)).toHaveCount(1);
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  expect(await page.evaluate(() => "__xss" in window)).toBe(false);
});

authedTest("WEB-2: a state-changing request from another origin is refused", async ({ page, context, baseURL }) => {
  const { xss } = seed();
  const path = `/api/videos/${xss.video_id}/views`;
  const origin = new URL(baseURL!).origin;

  // The same request from the app's own origin goes through, so the refusals below are the CSRF check's.
  const own = await page.request.post(path, { headers: { Origin: origin, "Sec-Fetch-Site": "same-origin" } });
  expect(own.status()).toBe(202);

  const refused = async (response: APIResponse) => {
    expect(response.status()).toBe(403);
    expect(await response.json()).toMatchObject({ code: "CSRF_REJECTED" });
  };
  await refused(await page.request.post(path, { headers: { Origin: "http://evil.example" } }));
  await refused(await page.request.post(path, { headers: { Origin: origin, "Sec-Fetch-Site": "cross-site" } }));
  await refused(await page.request.post(path, { headers: { Origin: origin, "Sec-Fetch-Site": "same-site" } }));
  await refused(await page.request.post(path, { headers: { Origin: "null" } }));
  await refused(await page.request.post(path));

  // A real browser posting a form from a page of another site: the browser sets Sec-Fetch-Site and Origin itself. Not a
  // fetch, which Chromium stops before it leaves the browser (a public site calling localhost). The form opens a new
  // window, so the browser's own rendering of the JSON answer is not counted as a CSP violation of this page.
  await context.route("http://evil.example/", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><title>evil</title><form method="post" action="${origin}${path}" target="_blank"><button>Send</button></form>`,
    }),
  );
  await page.goto("http://evil.example/");
  const [response] = await Promise.all([
    context.waitForEvent("response", (answer) => answer.url() === `${origin}${path}`),
    page.getByRole("button", { name: "Send" }).click(),
  ]);
  expect(response.status()).toBe(403);
});

test("WEB-4: next pointing to another site lands on /, a path of the app is kept", async ({ page, sessionAccount }) => {
  await logIn(page, sessionAccount, `/login?next=${encodeURIComponent("//evil.example")}`);
  await expect(page).toHaveURL("/");

  await logOut(page);
  await expect(page).toHaveURL("/login");
  await logIn(page, sessionAccount, `/login?next=${encodeURIComponent("/following")}`);
  await expect(page).toHaveURL("/following");
});

test("WEB-6: login sets a new session id; after logout the old cookie is refused", async ({
  page,
  context,
  browser,
  baseURL,
}) => {
  const account = await registerAccount();

  // A session id planted before login (fixation) is replaced, not adopted. HttpOnly, as the browser takes a
  // __Host-Http- cookie only with it (and Secure, which an https url gives); the plain name does not mind.
  const planted = randomBytes(32).toString("base64url");
  await context.addCookies([{ name: sessionCookie, value: planted, url: baseURL!, httpOnly: true }]);
  await logIn(page, account);
  await expect(page).toHaveURL("/");
  const cookie = (await context.cookies()).find((candidate) => candidate.name === sessionCookie);
  expect(cookie?.value).toBeTruthy();
  expect(cookie?.value).not.toBe(planted);
  expect(cookie).toMatchObject({ httpOnly: true, sameSite: "Lax", path: "/", secure: stack.secureCookie });
  const sid = cookie!.value;

  expect((await page.request.get("/api/feed/explore")).status()).toBe(200);

  await logOut(page);
  await expect(page).toHaveURL("/login");
  expect((await context.cookies()).some((candidate) => candidate.name === sessionCookie)).toBe(false);

  // The old cookie, sent again from another browser context, no longer opens a session.
  const replay = await browser.newContext({ baseURL, ...stack.contextOptions });
  try {
    await replay.addCookies([{ name: sessionCookie, value: sid, url: baseURL!, httpOnly: true }]);
    const answer = await replay.request.get("/api/feed/explore");
    expect(answer.status()).toBe(401);
  } finally {
    await replay.close();
  }
});

// The CSP header of an HTML response, and the nonce in it.
function cspOf(response: APIResponse): { csp: string; nonce: string } {
  expect(response.status()).toBe(200);
  const csp = response.headers()["content-security-policy"] ?? "";
  const nonce = /'nonce-([^']+)'/.exec(csp)?.[1] ?? "";
  expect(nonce, "nonce in the Content-Security-Policy header").not.toBe("");
  expect(csp).toContain(`script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`);
  expect(csp).toContain(`style-src 'self' 'nonce-${nonce}'`);
  for (const directive of ["object-src 'none'", "base-uri 'none'", "frame-ancestors 'none'"]) {
    expect(csp).toContain(directive);
  }
  expect(csp).not.toContain("unsafe-inline");
  expect(csp).not.toContain("unsafe-eval");
  return { csp, nonce };
}

// Read on the raw HTML: browsers hide the nonce attribute from the DOM.
async function expectScriptsCarryNonce(response: APIResponse, nonce: string): Promise<void> {
  const scripts = (await response.text()).match(/<script\b[^>]*>/g) ?? [];
  expect(scripts.length).toBeGreaterThan(0);
  for (const tag of scripts) {
    expect(tag).toContain(`nonce="${nonce}"`);
  }
}

test("CSP: login and register have a nonce on every script, new on every response", async ({ request }) => {
  for (const path of ["/login", "/register"]) {
    const first = await request.get(path);
    const { nonce } = cspOf(first);
    await expectScriptsCarryNonce(first, nonce);
    const second = cspOf(await request.get(path));
    expect(second.nonce).not.toBe(nonce);
  }
});

authedTest(
  "CSP: the pages of a logged-in user have a nonce on every script, new on every response",
  async ({ page }) => {
    for (const path of ["/", "/following", "/upload", "/me"]) {
      const first = await page.request.get(path);
      const { nonce } = cspOf(first);
      await expectScriptsCarryNonce(first, nonce);
      const second = cspOf(await page.request.get(path));
      expect(second.nonce).not.toBe(nonce);
    }
  },
);

test("CSP: the share page has a nonce on every script for a guest too", async ({ request }) => {
  const { xss } = seed();
  const path = `/v/${xss.video_id}`;
  const first = await request.get(path);
  const { nonce } = cspOf(first);
  await expectScriptsCarryNonce(first, nonce);
  expect(cspOf(await request.get(path)).nonce).not.toBe(nonce);
});

// The upload form posts to the storage from the page:
// UPLOAD_ORIGIN must be in connect-src, or the browser blocks the request.
authedTest("CSP: connect-src of /upload allows the upload origin", async ({ page }) => {
  const { csp } = cspOf(await page.request.get("/upload"));
  const connectSrc = csp
    .split(";")
    .map((directive) => directive.trim().split(/\s+/))
    .find(([name]) => name === "connect-src");
  expect(connectSrc, "connect-src directive").toBeDefined();
  expect(connectSrc).toContain(uploadOrigin);
});

// The object store's CORS is set per bucket and allows only the web's origins: uploads takes the upload form's POST,
// media the player's GET. A preflight from any other site, or for the other bucket's method, gets no
// Access-Control-Allow-Origin, so the browser sends nothing there. The store may answer such a preflight 403 or 200
// without the header, so only the header is checked. A preflight reads no object: the keys below need not exist.
test("WEB-10: the storage answers a preflight from the web's origin only, per bucket", async ({ request }) => {
  const allowOrigin = async (path: string, method: string, origin: string) =>
    (
      await request.fetch(`${uploadOrigin}${path}`, {
        method: "OPTIONS",
        headers: { Origin: origin, "Access-Control-Request-Method": method },
      })
    ).headers()["access-control-allow-origin"];
  const uploads = "/uploads";
  const media = "/media/media/web10-preflight/master.m3u8";
  const evil = "http://evil.example";

  expect(await allowOrigin(uploads, "POST", evil), `POST ${uploads} from ${evil}`).toBeUndefined();
  expect(await allowOrigin(uploads, "POST", stack.appOrigin), `POST ${uploads} from the web`).toBe(stack.appOrigin);
  expect(await allowOrigin(media, "GET", evil), `GET ${media} from ${evil}`).toBeUndefined();
  expect(await allowOrigin(media, "GET", stack.appOrigin), `GET ${media} from the web`).toBe(stack.appOrigin);
  // Each bucket allows only its own method, even to the web's origin.
  expect(await allowOrigin("/media", "POST", stack.appOrigin), "POST /media from the web").toBeUndefined();
  expect(
    await allowOrigin("/uploads/uploads/web10-preflight", "GET", stack.appOrigin),
    "GET /uploads/uploads/web10-preflight from the web",
  ).toBeUndefined();
});
