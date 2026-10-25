import type { Metric } from "web-vitals";

// Web vitals of the page load: the values
// web-vitals reports are kept, then sent together in one beacon to the app's own POST /rum when the page is hidden,
// which also happens when it is unloaded. `path` is the one the page loaded at, read by the caller at hydration:
// web-vitals starts only after the load event and its chunk, by which time a client-side navigation may have changed
// the URL. INP and CLS, which add up over the whole visit, count for the page the visit started on too.

export type WebVitals = Pick<typeof import("web-vitals"), "onLCP" | "onINP" | "onCLS" | "onFCP" | "onTTFB">;

// Starts watching; the returned function stops it without sending (the page turned into an error page).
export function watchVitals({ onLCP, onINP, onCLS, onFCP, onTTFB }: WebVitals, path: string): () => void {
  const values = new Map<Metric["name"], number>();
  let done = false;

  const keep = (metric: Metric) => {
    values.set(metric.name, metric.value);
  };
  for (const on of [onLCP, onINP, onCLS, onFCP, onTTFB]) {
    on(keep);
  }

  const stop = () => {
    done = true;
    removeEventListener("visibilitychange", onVisibilityChange);
  };

  function send() {
    if (done || values.size === 0) {
      return;
    }
    stop();
    const body = JSON.stringify({ path, metrics: [...values].map(([name, value]) => ({ name, value })) });
    // A string goes as text/plain, which needs no preflight; the beacon leaves even while the page unloads. Never
    // retried; fetch with keepalive only when the browser refused to queue the beacon.
    if (!navigator.sendBeacon(`${location.origin}/rum`, body)) {
      fetch(`${location.origin}/rum`, {
        method: "POST",
        keepalive: true,
        credentials: "omit",
        headers: { "Content-Type": "text/plain" },
        body,
      }).catch(() => {});
    }
  }

  function onVisibilityChange() {
    if (document.visibilityState === "hidden") {
      send();
    }
  }

  // On window and in the bubble phase: web-vitals reports the final CLS (0 on a page that never shifted) and INP only
  // from its own capture-phase listener of the same event, so they are in before this sends. No pagehide listener:
  // leaving the page fires pagehide first and visibilitychange to hidden right after it, so a beacon sent at pagehide
  // would leave CLS and INP out. A page put into the back/forward cache goes hidden the same way; when it comes back
  // the state is kept, so done stays set and the page load still sends one beacon.
  addEventListener("visibilitychange", onVisibilityChange);
  return stop;
}
