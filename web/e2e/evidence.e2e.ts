import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { expect, test, type Page, type TestInfo } from "@playwright/test";
import { feedItem, playingVideo, registerAccount, type Account } from "./fixtures";

// Screenshots of the screens of part A for a person to compare with the design frames of web/design (SVP Mobile,
// SVP Desktop): each screen full page at a phone and a desktop size, in Vietnamese, saved as
// <SVP_E2E_EVIDENCE>/screens/<browser>/<frame>-<name>-<mobile|desktop>.png. playwright.config.ts runs this file only
// when SVP_E2E_EVIDENCE is set. The password field is never switched to plain text, so no password shows; the only
// data changed is the run's own: a user registered here and a like on the seeded video of e2e/seed.sh.
//
// Playwright's own `test`, without the CSP watcher of e2e/fixtures.ts: in WebKit every page.screenshot() adds a
// <style> element to the page (Playwright toggles a style sheet to sync animations, whatever the options), which the
// app's CSP rightly refuses and the watcher would report. Every other spec runs the same pages under the watcher.

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
      path: join(process.env.SVP_E2E_EVIDENCE ?? "", "screens", testInfo.project.name, file),
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
