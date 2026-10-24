import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { authedTest, expect, feedItem, playingVideo } from "./fixtures";

// Time to first frame (docs/adr/0016-web-client.md, section 11): from the scroll that brings the next item on screen
// to its <video> playing (data-state="playing"), on 20 moves in a row, each to a video not played before in the run.
// The scroll is instant (scrollIntoView), so the number is the app's and the network's, not a scroll animation's. The
// samples and their p50/p95 go to test-results/first-frame-<project>.json for e2e/measure-web.sh.

const moves = 20;

// Nearest rank: the smallest sample with at least p of all samples at or below it.
function percentile(sorted: number[], p: number): number {
  return sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)]!;
}

authedTest("first frame after a swipe: p50 and p95 over 20 moves", async ({ page }, testInfo) => {
  authedTest.setTimeout(180_000);
  await page.goto("/");
  await expect(playingVideo(feedItem(page, 0))).toHaveCount(1);

  const samples: number[] = [];
  for (let index = 1; index <= moves; index++) {
    // The item is a video, not the item after the last one while the next page loads.
    await expect(feedItem(page, index).locator('[data-part="video-host"]')).toHaveCount(1);
    const ms = await feedItem(page, index).evaluate(
      (item, [move, timeoutMs]) =>
        new Promise<number>((resolve, reject) => {
          const start = performance.now();
          const playing = () => item.querySelector('video[data-state="playing"]') !== null;
          const observer = new MutationObserver(() => {
            if (playing()) {
              observer.disconnect();
              clearTimeout(timer);
              resolve(performance.now() - start);
            }
          });
          const timer = setTimeout(() => {
            observer.disconnect();
            // What the item's <video> was doing, so a failure tells a source that failed (data-state="error") from one
            // still loading or never asked to play.
            const video = item.querySelector("video");
            const state = video
              ? `data-state=${video.dataset.state ?? "none"} paused=${video.paused} readyState=${video.readyState} ` +
                `networkState=${video.networkState} error=${video.error?.code ?? "none"} ` +
                `currentTime=${video.currentTime.toFixed(2)} buffered=${video.buffered.length}`
              : "no <video> in the item";
            reject(new Error(`move ${move}: the video did not play (${state})`));
          }, timeoutMs);
          // Watched before the scroll, so no change the scroll causes is missed.
          observer.observe(item, { subtree: true, childList: true, attributes: true, attributeFilter: ["data-state"] });
          item.scrollIntoView({ block: "start", behavior: "instant" });
        }),
      [index, 15_000] as const,
    );
    samples.push(ms);
  }

  const sorted = [...samples].sort((a, b) => a - b);
  const result = {
    project: testInfo.project.name,
    moves,
    p50_ms: Math.round(percentile(sorted, 0.5)),
    p95_ms: Math.round(percentile(sorted, 0.95)),
    max_ms: Math.round(sorted[sorted.length - 1]!),
    samples_ms: samples.map((sample) => Math.round(sample)),
  };
  const dir = join(import.meta.dirname, "..", "test-results");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `first-frame-${testInfo.project.name}.json`), `${JSON.stringify(result, null, 2)}\n`);
  console.log(
    `first frame ${result.project}: p50 ${result.p50_ms} ms, p95 ${result.p95_ms} ms, max ${result.max_ms} ms`,
  );
});
