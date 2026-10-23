import { isAbsolute, join } from "node:path";
import { defineConfig, devices, type ReporterDescription } from "@playwright/test";
import { stack } from "./e2e/stack";

// SVP_E2E_EVIDENCE=<absolute folder> turns the run into one a person can review afterwards: trace, video and (Chromium
// only, see the webkit project) a final screenshot of every test, an HTML report (<folder>/report) and a JSON one
// (<folder>/results.json), the artefacts under <folder>/artifacts, and e2e/evidence.e2e.ts, which takes full-page
// screenshots of every screen into <folder>/screens. Without it the run is the plain one of `make web-e2e` and CI.
const evidence = process.env.SVP_E2E_EVIDENCE;
if (evidence !== undefined && !isAbsolute(evidence)) {
  throw new Error("SVP_E2E_EVIDENCE must be an absolute path");
}

const reporter: ReporterDescription[] = [["list"], ["./e2e/summary-reporter.ts"]];
if (evidence) {
  reporter.push(
    ["html", { outputFolder: join(evidence, "report"), open: "never" }],
    ["json", { outputFile: join(evidence, "results.json") }],
  );
}

// SVP_E2E_MEASURE_UPLOAD_FILE=<video file> is set by e2e/measure-upload.sh (`make measure-upload`) only: the run is the
// upload measurement of e2e/measure-upload.e2e.ts, which no other run includes.
const measureUpload = process.env.SVP_E2E_MEASURE_UPLOAD_FILE;

// SVP_E2E_GLITCHTIP=1 adds e2e/glitchtip.e2e.ts: a real error in the browser bundle, then the GlitchTip API until
// its event shows frames mapped to the source. It needs GlitchTip with the source maps uploaded, so a plain run leaves
// it out.
const glitchtip = process.env.SVP_E2E_GLITCHTIP === "1";

const chromium = { ...devices["Desktop Chrome"] };
const webkit = {
  ...devices["Desktop Safari"],
  // No screenshot at the end of each test in WebKit: Playwright adds a <style> element to the page for every WebKit
  // screenshot, which the app's CSP refuses and the CSP watcher of e2e/fixtures.ts reports as a failure. The trace and
  // the video still record every WebKit test.
  ...(evidence ? { screenshot: "off" as const } : {}),
};

// Tests tagged @publishes make a video READY, and the newest READY video leads Explore. Other tests expect the WEB-1
// video of e2e/seed.sh to lead it, so the publishing tests run in projects of their own, listed last: with one worker,
// Playwright runs the projects one after the other in this order, so both browsers have run every other test first.
const publishes = /@publishes/;

// End-to-end tests of the web client on the compose stack of `make up` (`make web-e2e`, `make measure-web`): the
// browser opens the `web` container at http://localhost:3001, the origin its CSRF check and cookie form expect
// (docs/adr/0016-web-client.md, sections 5 and 7). With SVP_STACK=k3d (`make k8s-web-e2e`) the same tests, on both
// browsers, open the web of cluster svp at https://svp.localhost:8443 instead (e2e/stack.ts). e2e/global-setup.ts
// seeds the videos through the gateway first.
export default defineConfig({
  testDir: "./e2e",
  // Not *.test.ts or *.spec.ts: those names belong to the unit tests of vitest.config.ts.
  testMatch: "**/*.e2e.ts",
  // The screenshots of e2e/evidence.e2e.ts are only wanted in an evidence run, the upload measurement only in its own.
  testIgnore: [
    ...(evidence ? [] : ["**/evidence.e2e.ts"]),
    ...(measureUpload ? [] : ["**/measure-upload.e2e.ts"]),
    ...(glitchtip ? [] : ["**/glitchtip.e2e.ts"]),
  ],
  // A subfolder, because Playwright empties its output folder at the start of a run and e2e/measure-web.sh reads the
  // measurements the first-frame test writes next to it.
  outputDir: evidence ? join(evidence, "artifacts") : "./test-results/playwright",
  globalSetup: "./e2e/global-setup.ts",
  // One browser at a time on the 16 GB machine; the tests also share one gateway rate limit bucket (e2e/fixtures.ts).
  workers: 1,
  fullyParallel: false,
  retries: 0,
  forbidOnly: true,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter,
  use: {
    baseURL: stack.appOrigin,
    ...stack.contextOptions,
    // English copy, so the tests find controls by the names in messages/en.
    locale: "en-US",
    trace: evidence ? "on" : "retain-on-failure",
    screenshot: evidence ? "on" : "off",
    video: evidence ? "on" : "off",
  },
  projects: [
    { name: "chromium", grepInvert: publishes, use: chromium },
    { name: "webkit", grepInvert: publishes, use: webkit },
    { name: "chromium-publishing", grep: publishes, use: chromium },
    { name: "webkit-publishing", grep: publishes, use: webkit },
  ],
});
