import { execFileSync } from "node:child_process";
import { statSync, writeFileSync } from "node:fs";
import { expect, logIn, registerAccount, test } from "./fixtures";

// The upload measurement of e2e/measure-upload.sh (`make measure-upload`), Chromium only: one ~100 MB video through
// /upload, the way a user sends it (docs/adr/0018-web-profiles-public-video-upload.md, section 8).
// - Upload time: the Resource Timing entry of the XHR's POST to the storage, startTime to responseEnd. It includes the
//   CORS preflight, which is part of what the user waits for.
// - CPU: DevTools Performance.getMetrics before the click and right after the POST ended. TaskDuration is the time the
//   page's main thread was busy, ScriptDuration the part of it running JavaScript (the progress events and React).
//   The bytes themselves go out from Chromium's network process, which these metrics do not count.
// - READY: polled once a second through the web's API from the XHR's start.
// The file comes from SVP_E2E_MEASURE_UPLOAD_FILE; the result goes to SVP_E2E_MEASURE_UPLOAD_OUT.

const file = process.env.SVP_E2E_MEASURE_UPLOAD_FILE ?? "";
const out = process.env.SVP_E2E_MEASURE_UPLOAD_OUT ?? "";

type Metrics = Record<string, number>;

test("measure: upload of a ~100 MB video, then READY", { tag: "@publishes" }, async ({ page, context }) => {
  // 160 s of 1080p takes the worker a few minutes.
  test.setTimeout(600_000);
  expect(out, "SVP_E2E_MEASURE_UPLOAD_OUT").not.toBe("");
  const sizeBytes = statSync(file).size;
  const durationS = Number(
    execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file], {
      encoding: "utf8",
    }),
  );

  await logIn(page, await registerAccount());
  await expect(page).toHaveURL("/");
  await page.goto("/upload");
  await page.locator('input[type="file"]').setInputFiles(file);
  await page.getByLabel("Title").fill("measure upload");

  const cdp = await context.newCDPSession(page);
  await cdp.send("Performance.enable");
  const metrics = async (): Promise<Metrics> =>
    Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map(({ name, value }) => [name, value]));

  const created = page.waitForResponse(
    (response) => response.request().method() === "POST" && new URL(response.url()).pathname === "/api/videos",
  );
  const before = await metrics();
  await page.getByRole("button", { name: "Post video" }).click();
  const videoId = ((await (await created).json()) as { video_id: string }).video_id;

  // The POST's entry appears once its response has ended.
  const uploadEntry = () =>
    page.evaluate(() => {
      const entry = performance
        .getEntriesByType("resource")
        .find(
          (candidate) =>
            candidate.name.startsWith("http://127.0.0.1:9000/") &&
            (candidate as PerformanceResourceTiming).initiatorType === "xmlhttprequest",
        );
      return entry ? { start: performance.timeOrigin + entry.startTime, ms: entry.duration } : null;
    });
  await expect.poll(uploadEntry, { timeout: 120_000, intervals: [100] }).not.toBeNull();
  const after = await metrics();
  const upload = (await uploadEntry())!;

  await expect
    .poll(
      async () => ((await (await page.request.get(`/api/videos/${videoId}`)).json()) as { status: string }).status,
      { timeout: 540_000, intervals: [1000] },
    )
    .toBe("READY");
  const readyMs = Date.now() - upload.start;

  const delta = (name: string) => Math.round((after[name]! - before[name]!) * 1000);
  const windowMs = delta("Timestamp");
  const result = {
    measured_at: new Date().toISOString(),
    browser: "chromium",
    conditions: "compose stack on this machine, browser to MinIO over loopback (127.0.0.1:9000), no throttling",
    file_mb: Number((sizeBytes / 1e6).toFixed(1)),
    duration_s: Math.round(durationS),
    upload_ms: Math.round(upload.ms),
    throughput_mb_s: Number((sizeBytes / 1e6 / (upload.ms / 1000)).toFixed(1)),
    cpu: {
      window_ms: windowMs,
      task_ms: delta("TaskDuration"),
      script_ms: delta("ScriptDuration"),
      task_share_pct: Math.round((delta("TaskDuration") / windowMs) * 100),
    },
    ready_ms: Math.round(readyMs),
  };
  writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
});
