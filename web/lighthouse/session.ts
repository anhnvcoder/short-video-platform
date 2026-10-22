import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "@playwright/test";

// Logs a user in through the web's login page in Playwright's Chromium, as a person would, and writes the session
// cookie for lighthouse/run.sh into the private work folder it names: headers.json ({"Cookie": ...}) for Lighthouse's
// extraHeaders and cookie.txt (a "Cookie: ..." line) for curl's -H @file at logout. The cookie is never printed.
//
// Usage: node lighthouse/session.ts WEB_URL CREDENTIALS_FILE WORK_DIR, where CREDENTIALS_FILE holds
// {"email", "password"} as new_user of deploy/compose/lib.sh writes it.
const [webURL, credentialsFile, workDir] = process.argv.slice(2);
if (!webURL || !credentialsFile || !workDir) {
  throw new Error("usage: node lighthouse/session.ts WEB_URL CREDENTIALS_FILE WORK_DIR");
}
const { email, password } = JSON.parse(readFileSync(credentialsFile, "utf8")) as { email: string; password: string };

const browser = await chromium.launch();
try {
  // English copy, so the controls have the names of messages/en.
  const context = await browser.newContext({ baseURL: webURL, locale: "en-US" });
  const page = await context.newPage();
  await page.goto("/login");
  await page.getByLabel("Email").fill(email);
  // Exact: the eye button next to the field is labelled "Show password".
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await page.waitForURL("/", { timeout: 15_000 });
  const cookies = await context.cookies(webURL);
  if (cookies.length === 0) {
    throw new Error("the login set no cookie");
  }
  const cookie = cookies.map(({ name, value }) => `${name}=${value}`).join("; ");
  writeFileSync(join(workDir, "headers.json"), JSON.stringify({ Cookie: cookie }), { mode: 0o600 });
  writeFileSync(join(workDir, "cookie.txt"), `Cookie: ${cookie}\n`, { mode: 0o600 });
  console.log(`ok    logged in through the web (${cookies.length} cookies kept for Lighthouse)`);
} finally {
  await browser.close();
}
