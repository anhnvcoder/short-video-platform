import { randomBytes } from "node:crypto";
import { test as base, expect, type BrowserContext, type Locator, type Page } from "@playwright/test";

// Shared helpers of the end-to-end tests.
//
// Rate limits: the BFF reaches the gateway from the one address of the `web` container, so all browsers share the
// gateway's per-IP buckets (docs/adr/0016-web-client.md, section 4): register (burst 20 per hour), login-ip (burst 30,
// 60 per minute). Test users are therefore registered straight at the gateway, and each project logs in through the
// web about 8 times and registers through it once (the main flow); e2e/seed.sh resets the register bucket before every
// run. Each user logs in at most 3 times, under the login-email burst of 5.

// The gateway as e2e/seed.sh reaches it, on the host's loopback.
const gatewayURL = "http://127.0.0.1:8080";

export type Account = { email: string; password: string };

// A fresh random user, registered at the gateway. Every run gets new users, so no test depends on an earlier run.
export async function registerAccount(): Promise<Account> {
  const account = {
    email: `e2e-${Date.now()}-${randomBytes(4).toString("hex")}@example.test`,
    password: randomBytes(16).toString("hex"),
  };
  const response = await fetch(`${gatewayURL}/auth/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(account),
    signal: AbortSignal.timeout(5000),
  });
  if (response.status !== 201) {
    throw new Error(`register at the gateway answered ${response.status}`);
  }
  return account;
}

// Fills and sends the form of the login page at `path` (which may carry `next`).
export async function logIn(page: Page, account: Account, path = "/login"): Promise<void> {
  await page.goto(path);
  await fillAuthForm(page, account);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
}

export async function fillAuthForm(page: Page, account: Account): Promise<void> {
  await page.getByLabel("Email").fill(account.email);
  // Exact: the eye button next to the field is labelled "Show password".
  await page.getByLabel("Password", { exact: true }).fill(account.password);
}

// The shell has a logout button in the desktop sidebar and one in the bottom bar; only one of them shows.
export async function logOut(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Log out" }).filter({ visible: true }).click();
}

// Item `index` of the vertical feed (features/feed/feed-screen.tsx); the one after the last video is the tail.
export function feedItem(page: Page, index: number): Locator {
  return page.locator(`[role="feed"] > article[data-index="${index}"]`);
}

// The player marks the <video> it moved into an item with data-state (features/feed/player-pool.ts).
export function playingVideo(item: Locator): Locator {
  return item.locator('video[data-state="playing"]');
}

type StorageState = Awaited<ReturnType<BrowserContext["storageState"]>>;

type WorkerFixtures = {
  // A user of this worker, logged in once through the login page; its cookie is kept for the tests of `authedTest`.
  sessionAccount: Account & { storageState: StorageState };
};

type TestFixtures = {
  // Every Content-Security-Policy violation of the test's page: the event of the document and the console message
  // the browser logs. The test fails when there is any.
  cspViolations: string[];
};

export const test = base.extend<TestFixtures, WorkerFixtures>({
  cspViolations: [
    async ({ page }, provide) => {
      const violations: string[] = [];
      await page.exposeFunction("__svpCspViolation", (violation: string) => violations.push(violation));
      await page.addInitScript(() => {
        document.addEventListener("securitypolicyviolation", (event) => {
          const report = (window as unknown as { __svpCspViolation: (violation: string) => void }).__svpCspViolation;
          report(
            `${event.effectiveDirective} blocked ${event.blockedURI || "inline"} (${event.sourceFile}:${event.lineNumber})`,
          );
        });
      });
      page.on("console", (message) => {
        if (
          /content[- ]security[- ]policy|refused to (load|execute|apply|connect|frame|create)/i.test(message.text())
        ) {
          violations.push(`console: ${message.text()}`);
        }
      });
      await provide(violations);
      expect(violations, "Content-Security-Policy violations").toEqual([]);
    },
    { auto: true },
  ],
  sessionAccount: [
    async ({ browser }, provide, workerInfo) => {
      const account = await registerAccount();
      const { baseURL, locale } = workerInfo.project.use;
      const context = await browser.newContext({ baseURL, locale });
      const page = await context.newPage();
      await logIn(page, account);
      await page.waitForURL("/");
      const storageState = await context.storageState();
      await context.close();
      await provide({ ...account, storageState });
    },
    { scope: "worker" },
  ],
});

// Tests that start logged in as the worker's sessionAccount. They must not log it out: the others share its session.
export const authedTest = test.extend({
  storageState: async ({ sessionAccount }, provide) => provide(sessionAccount.storageState),
});

export { expect };
