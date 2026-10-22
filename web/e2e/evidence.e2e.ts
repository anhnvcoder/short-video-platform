import { randomBytes, randomUUID } from "node:crypto";
import { join } from "node:path";
import { expect, type Page, type Route, type TestInfo } from "@playwright/test";
import {
  feedItem,
  generatedHandle,
  playingVideo,
  randomHandle,
  registerAccount,
  test as fixturesTest,
  testClip,
  uploadURL,
  type Account,
} from "./fixtures";
import { seed } from "./seed";

// Screenshots of the screens of the web client for a person to compare with the design frames of web/design (SVP
// Mobile, SVP Desktop): each screen full page at a phone and a desktop size, in Vietnamese, saved as
// <SVP_E2E_EVIDENCE>/screens/<browser>/<frame>-<name>-<mobile|desktop>.png. playwright.config.ts runs this file only
// when SVP_E2E_EVIDENCE is set. The password field is never switched to plain text, so no password shows; the only
// data changed is the run's own: users registered here, a like on the seeded video of e2e/seed.sh, a follow of its
// author, and one uploaded clip.
//
// The `test` of e2e/fixtures.ts, for its worker set-up (the register rate limit reset), with its CSP watcher turned off:
// in WebKit every page.screenshot() adds a <style> element to the page (Playwright toggles a style sheet to sync
// animations, whatever the options), which the app's CSP rightly refuses and the watcher would report. Every other spec
// runs the same pages under the watcher.
// The override keeps the fixture automatic, so it still runs for every test, now without a page or a check.
const test = fixturesTest.extend({ cspViolations: async ({}, provide) => provide([]) });

test.use({ locale: "vi-VN" });

const sizes = [
  { name: "mobile", viewport: { width: 390, height: 844 } },
  { name: "desktop", viewport: { width: 1440, height: 900 } },
] as const;

type Frames = { mobile: string; desktop: string };

// Takes the screen as it is now at both sizes. `ready` waits until the screen settled again after a resize.
async function shoot(page: Page, testInfo: TestInfo, frames: Frames, name: string, ready: () => Promise<void>) {
  for (const size of sizes) {
    await page.setViewportSize(size.viewport);
    await ready();
    const file = `${frames[size.name]}-${name}-${size.name}.png`;
    await page.screenshot({
      // By browser: the tests tagged @publishes run in projects of their own (playwright.config.ts).
      path: join(
        process.env.SVP_E2E_EVIDENCE ?? "",
        "screens",
        testInfo.project.name.replace(/-publishing$/, ""),
        file,
      ),
      fullPage: true,
      animations: "disabled",
    });
  }
}

async function fillForm(page: Page, email: string, password: string): Promise<void> {
  await page.getByLabel("Email").fill(email);
  // Exact: the eye button next to the field is labelled "Hiện mật khẩu".
  await page.getByLabel("Mật khẩu", { exact: true }).fill(password);
}

async function logIn(page: Page, account: Account): Promise<void> {
  await page.goto("/login");
  await fillForm(page, account.email, account.password);
  await page.getByRole("button", { name: "Đăng nhập", exact: true }).click();
  await expect(page).toHaveURL("/");
}

test("evidence: login, register and 404 screens", async ({ page }, testInfo) => {
  const account = await registerAccount();
  const heading = (name: string) => () => expect(page.getByRole("heading", { level: 1, name })).toBeVisible();

  await page.goto("/login");
  await shoot(page, testInfo, { mobile: "M13", desktop: "D07" }, "dang-nhap", heading("Đăng nhập"));

  // Checked in the browser, before any request.
  await fillForm(page, "ten@", "123");
  await page.getByRole("button", { name: "Đăng nhập", exact: true }).click();
  await shoot(page, testInfo, { mobile: "M14", desktop: "M14" }, "loi-truong", () =>
    expect(page.getByText("Email không đúng định dạng", { exact: false })).toBeVisible(),
  );

  await fillForm(page, account.email, randomBytes(16).toString("hex"));
  await page.getByRole("button", { name: "Đăng nhập", exact: true }).click();
  await shoot(page, testInfo, { mobile: "M15", desktop: "M15" }, "sai-thong-tin", () =>
    expect(page.getByText("Email hoặc mật khẩu không đúng")).toBeVisible(),
  );

  await page.goto("/register");
  await shoot(page, testInfo, { mobile: "M18", desktop: "D08" }, "dang-ky", heading("Tạo tài khoản"));

  await fillForm(page, account.email, randomBytes(16).toString("hex"));
  await page.getByLabel("Tên người dùng").fill(randomHandle());
  await page.getByRole("button", { name: "Tạo tài khoản", exact: true }).click();
  await shoot(page, testInfo, { mobile: "M19", desktop: "M19" }, "email-da-dung", () =>
    expect(page.getByText("Email này đã được dùng.")).toBeVisible(),
  );

  await page.goto(`/khong-co-trang-${randomBytes(4).toString("hex")}`);
  await shoot(page, testInfo, { mobile: "M39", desktop: "D11" }, "404", heading("Không tìm thấy trang"));
});

test("evidence: Explore playing, liked, empty Following", async ({ page }, testInfo) => {
  await logIn(page, await registerAccount());
  const first = feedItem(page, 0);
  const playing = () => expect(playingVideo(first)).toHaveCount(1);

  await shoot(page, testInfo, { mobile: "M01", desktop: "D01" }, "kham-pha-dang-phat", playing);

  // Named "Thích video, <count>" or "Bỏ thích video, <count>" with stats, "Thích video" without; aria-pressed tells.
  const like = first.getByRole("button", { name: /^(Bỏ thích|Thích) video/ });
  await like.click();
  await expect(like).toHaveAttribute("aria-pressed", "true");
  await shoot(page, testInfo, { mobile: "M02", desktop: "M02" }, "da-thich", async () => {
    await playing();
    await expect(like).toHaveAttribute("aria-pressed", "true");
  });

  // A new user follows nobody.
  await page.getByRole("tab", { name: "Đang theo dõi" }).click();
  await expect(page).toHaveURL("/following");
  await shoot(page, testInfo, { mobile: "M11", desktop: "M11" }, "dang-theo-doi-trong", () =>
    expect(page.getByText("Bạn chưa theo dõi ai")).toBeVisible(),
  );
});

test("evidence: profiles, the share page for a guest and logged in, its 404", async ({ page, browser }, testInfo) => {
  const { xss } = seed();
  const handle = generatedHandle(xss.author_id);

  // A guest, in a context without any cookie.
  const guestContext = await browser.newContext({ baseURL: testInfo.project.use.baseURL, locale: "vi-VN" });
  try {
    const guest = await guestContext.newPage();
    await guest.goto(`/v/${xss.video_id}`);
    const playing = () => expect(playingVideo(guest.locator("article"))).toHaveCount(1);
    await shoot(guest, testInfo, { mobile: "M38", desktop: "D04" }, "chia-se-khach", playing);
    // The side panel's like button on a wide screen, the one over the video on a small one.
    await guest
      .getByRole("button", { name: /^Thích/ })
      .filter({ visible: true })
      .first()
      .click();
    await shoot(guest, testInfo, { mobile: "M09", desktop: "D03" }, "chia-se-moi-dang-nhap", () =>
      expect(guest.getByRole("dialog", { name: "Đăng nhập để thích video" })).toBeVisible(),
    );
    await guest.goto(`/v/${randomUUID()}`);
    await shoot(guest, testInfo, { mobile: "M39", desktop: "D11" }, "video-404", () =>
      expect(guest.getByRole("heading", { level: 1, name: "Không tìm thấy video" })).toBeVisible(),
    );
  } finally {
    await guestContext.close();
  }

  await logIn(page, await registerAccount());
  await page.goto(`/v/${xss.video_id}`);
  await shoot(page, testInfo, { mobile: "M38", desktop: "D04" }, "chia-se-da-dang-nhap", () =>
    expect(playingVideo(page.locator("article"))).toHaveCount(1),
  );

  await page.goto(`/u/${handle}`);
  const follow = page.getByRole("button", { name: "Theo dõi", exact: true });
  await shoot(page, testInfo, { mobile: "M35", desktop: "D10" }, "ho-so", () => expect(follow).toBeVisible());
  await follow.click();
  await shoot(page, testInfo, { mobile: "M36", desktop: "D10" }, "ho-so-dang-theo-doi", () =>
    expect(page.getByRole("button", { name: "Đang theo dõi", exact: true })).toHaveAttribute("aria-pressed", "true"),
  );
});

// Tagged @publishes: the clip becomes READY and leads Explore (playwright.config.ts).
test("evidence: the upload steps and My videos", { tag: "@publishes" }, async ({ page, context }, testInfo) => {
  test.slow();
  await logIn(page, await registerAccount());
  await page.goto("/upload");
  const heading = page.getByRole("heading", { level: 1, name: "Tải video lên" });
  await shoot(page, testInfo, { mobile: "M20", desktop: "D05" }, "chon-file", () => expect(heading).toBeVisible());

  // A short small clip: it transcodes in seconds.
  await page.locator('input[type="file"]').setInputFiles(testClip(4, "360x640"));
  await page.getByLabel("Tiêu đề").fill(`Clip thử ${randomBytes(2).toString("hex")}`);
  await shoot(page, testInfo, { mobile: "M25", desktop: "M25" }, "chi-tiet", () =>
    expect(page.getByRole("button", { name: "Đăng video" })).toBeVisible(),
  );

  // Over loopback the file goes up in a blink. The first POST to the storage is held for the progress screen, then
  // aborted with the browser offline for the lost connection screen; the next one goes through.
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  let posts = 0;
  await page.route(`${uploadURL}*`, async (route: Route) => {
    if (route.request().method() === "POST" && ++posts === 1) {
      await held;
      await context.setOffline(true);
      await route.abort("internetdisconnected");
    } else {
      await route.continue();
    }
  });
  await page.getByRole("button", { name: "Đăng video" }).click();
  await shoot(page, testInfo, { mobile: "M28", desktop: "D06" }, "dang-tai-len", async () => {
    await expect(page.getByRole("progressbar", { name: "Tiến độ tải lên" })).toBeVisible();
    await expect.poll(() => posts).toBe(1);
  });
  release();
  await shoot(page, testInfo, { mobile: "M29", desktop: "M29" }, "mat-ket-noi", () =>
    expect(page.getByText("Mất kết nối")).toBeVisible(),
  );
  await context.setOffline(false);

  await expect(page.getByText("Đang xử lý video")).toBeVisible();
  await shoot(page, testInfo, { mobile: "M30", desktop: "M30" }, "dang-xu-ly", async () => {
    await expect(page.getByText(/Đang xử lý video|Video đã sẵn sàng/)).toBeVisible();
  });
  await expect(page.getByText("Video đã sẵn sàng")).toBeVisible({ timeout: 120_000 });
  await shoot(page, testInfo, { mobile: "M31", desktop: "M31" }, "san-sang", () =>
    expect(page.getByRole("link", { name: "Xem video" })).toBeVisible(),
  );

  await page.goto("/me");
  await shoot(page, testInfo, { mobile: "M33", desktop: "D09" }, "video-cua-toi", () =>
    expect(page.getByText("Sẵn sàng").filter({ visible: true }).first()).toBeVisible(),
  );
});
