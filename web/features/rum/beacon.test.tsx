import { render } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import type { Metric } from "web-vitals";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { watchVitals, type WebVitals } from "./beacon";

// web-vitals as the page sees it: each on* registers a callback the test fires with a value.
function fakeWebVitals() {
  // Each on* takes a callback of its own metric type; the fake keeps them all alike.
  const callbacks = new Map<Metric["name"], (metric: never) => void>();
  const on = (name: Metric["name"]) => (callback: (metric: never) => void) => {
    callbacks.set(name, callback);
  };
  const webVitals: WebVitals = {
    onLCP: on("LCP"),
    onINP: on("INP"),
    onCLS: on("CLS"),
    onFCP: on("FCP"),
    onTTFB: on("TTFB"),
  };
  const report = (name: Metric["name"], value: number) => callbacks.get(name)!({ name, value } as never);
  return { webVitals, report, callbacks };
}

let visibility: DocumentVisibilityState = "visible";

const videoPath = "/v/0b7c9a2e-1f3d-4e5a-8b6c-7d8e9f0a1b2c";

function hide() {
  visibility = "hidden";
  document.dispatchEvent(new Event("visibilitychange", { bubbles: true }));
}

const sendBeacon = vi.fn<(url: string, body: string) => boolean>();

beforeEach(() => {
  visibility = "visible";
  vi.spyOn(document, "visibilityState", "get").mockImplementation(() => visibility);
  sendBeacon.mockReset().mockReturnValue(true);
  Object.defineProperty(navigator, "sendBeacon", { value: sendBeacon, configurable: true });
  window.history.replaceState(null, "", videoPath);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.doUnmock("web-vitals");
  window.history.replaceState(null, "", "/");
});

const sent = (call = 0) => JSON.parse(sendBeacon.mock.calls[call]![1]) as unknown;

describe("watchVitals", () => {
  it("sends every metric in one beacon to /rum when the page is hidden, with the path it was given", () => {
    const { webVitals, report } = fakeWebVitals();
    const stop = watchVitals(webVitals, videoPath);
    report("TTFB", 210);
    report("FCP", 640);
    // A client-side navigation does not change the page the visit is counted for.
    window.history.pushState(null, "", "/following");
    report("LCP", 1830.4);
    report("CLS", 0.02);
    expect(sendBeacon).not.toHaveBeenCalled();

    hide();
    expect(sendBeacon).toHaveBeenCalledOnce();
    expect(sendBeacon.mock.calls[0]![0]).toBe(`${location.origin}/rum`);
    expect(sent()).toEqual({
      path: videoPath,
      metrics: [
        { name: "TTFB", value: 210 },
        { name: "FCP", value: 640 },
        { name: "LCP", value: 1830.4 },
        { name: "CLS", value: 0.02 },
      ],
    });
    stop();
  });

  it("sends once per page: a later hide or pagehide sends nothing more", () => {
    const { webVitals, report } = fakeWebVitals();
    watchVitals(webVitals, videoPath);
    report("LCP", 1000);
    hide();
    report("INP", 80);
    visibility = "visible";
    hide();
    window.dispatchEvent(new Event("pagehide"));
    expect(sendBeacon).toHaveBeenCalledOnce();
  });

  it("keeps the last value of a metric", () => {
    const { webVitals, report } = fakeWebVitals();
    watchVitals(webVitals, videoPath);
    report("CLS", 0.01);
    report("CLS", 0.04);
    hide();
    expect(sent()).toEqual({
      path: videoPath,
      metrics: [{ name: "CLS", value: 0.04 }],
    });
  });

  // Leaving the page fires pagehide first, then visibilitychange to hidden; web-vitals reports the final CLS (0 on a
  // page that never shifted) and INP only from its capture-phase listener of visibilitychange.
  it("on leaving the page, sends the CLS and INP that web-vitals reports at visibilitychange after pagehide", () => {
    const { webVitals, report } = fakeWebVitals();
    const reportFinal = () => {
      if (document.visibilityState === "hidden") {
        report("CLS", 0);
        report("INP", 120);
      }
    };
    addEventListener("visibilitychange", reportFinal, { capture: true });
    try {
      const stop = watchVitals(webVitals, videoPath);
      report("LCP", 900);
      window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: false }));
      hide();
      expect(sendBeacon).toHaveBeenCalledOnce();
      expect(sent()).toEqual({
        path: videoPath,
        metrics: [
          { name: "LCP", value: 900 },
          { name: "CLS", value: 0 },
          { name: "INP", value: 120 },
        ],
      });
      stop();
    } finally {
      removeEventListener("visibilitychange", reportFinal, { capture: true });
    }
  });

  it("sends one beacon per page load when the page goes into the back/forward cache and comes back", () => {
    const { webVitals, report } = fakeWebVitals();
    watchVitals(webVitals, videoPath);
    report("CLS", 0);
    window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true }));
    hide();
    expect(sendBeacon).toHaveBeenCalledOnce();
    // Restored from the cache: same page load, same state.
    visibility = "visible";
    document.dispatchEvent(new Event("visibilitychange", { bubbles: true }));
    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));
    report("CLS", 0.03);
    window.dispatchEvent(new PageTransitionEvent("pagehide", { persisted: false }));
    hide();
    expect(sendBeacon).toHaveBeenCalledOnce();
  });

  it("sends nothing while no metric has been reported, then sends at the next hide", () => {
    const { webVitals, report } = fakeWebVitals();
    watchVitals(webVitals, videoPath);
    hide();
    expect(sendBeacon).not.toHaveBeenCalled();
    report("TTFB", 100);
    visibility = "visible";
    hide();
    expect(sendBeacon).toHaveBeenCalledOnce();
  });

  it("sends nothing after it was stopped", () => {
    const { webVitals, report } = fakeWebVitals();
    const stop = watchVitals(webVitals, videoPath);
    report("LCP", 1000);
    stop();
    hide();
    window.dispatchEvent(new Event("pagehide"));
    expect(sendBeacon).not.toHaveBeenCalled();
  });

  it("falls back to fetch with keepalive, text/plain and no credentials when the beacon is refused", async () => {
    sendBeacon.mockReturnValue(false);
    const received: { body: string; contentType: string | null }[] = [];
    server.use(
      http.post(`${location.origin}/rum`, async ({ request }) => {
        received.push({ body: await request.text(), contentType: request.headers.get("content-type") });
        return new HttpResponse(null, { status: 204 });
      }),
    );
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const { webVitals, report } = fakeWebVitals();
    watchVitals(webVitals, videoPath);
    report("INP", 96);
    hide();
    await vi.waitFor(() => expect(received).toHaveLength(1));
    expect(JSON.parse(received[0]!.body)).toEqual({
      path: videoPath,
      metrics: [{ name: "INP", value: 96 }],
    });
    expect(received[0]!.contentType).toBe("text/plain");
    expect(fetchSpy.mock.calls[0]![1]).toMatchObject({ method: "POST", keepalive: true, credentials: "omit" });
  });
});

describe("VitalsReporter", () => {
  async function renderReporter() {
    const fake = fakeWebVitals();
    vi.doMock("web-vitals", () => fake.webVitals);
    vi.resetModules();
    const { VitalsReporter } = await import("./vitals-reporter");
    return { ...fake, ...render(<VitalsReporter />) };
  }

  it("loads web-vitals after the page has loaded and starts watching", async () => {
    const { callbacks, report } = await renderReporter();
    await vi.waitFor(() => expect(callbacks.size).toBe(5));
    report("LCP", 1200);
    hide();
    expect(sent()).toMatchObject({ metrics: [{ name: "LCP", value: 1200 }] });
  });

  it("counts the vitals for the page it hydrated on, after a client-side navigation before the load event", async () => {
    let state: DocumentReadyState = "loading";
    vi.spyOn(document, "readyState", "get").mockImplementation(() => state);
    const { callbacks, report } = await renderReporter();
    // Tapping a link on a slow network: the URL changes before the page's load event and web-vitals' chunk.
    window.history.pushState(null, "", "/following");
    state = "complete";
    window.dispatchEvent(new Event("load"));
    await vi.waitFor(() => expect(callbacks.size).toBe(5));
    report("LCP", 2600);
    hide();
    expect(sent()).toEqual({ path: videoPath, metrics: [{ name: "LCP", value: 2600 }] });
  });

  it("waits for the load event before it loads web-vitals", async () => {
    let state: DocumentReadyState = "loading";
    vi.spyOn(document, "readyState", "get").mockImplementation(() => state);
    const { callbacks } = await renderReporter();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(callbacks.size).toBe(0);
    state = "complete";
    window.dispatchEvent(new Event("load"));
    await vi.waitFor(() => expect(callbacks.size).toBe(5));
  });

  it("sends nothing once unmounted, as when global-error replaces the root layout", async () => {
    const { callbacks, report, unmount } = await renderReporter();
    await vi.waitFor(() => expect(callbacks.size).toBe(5));
    report("LCP", 1200);
    unmount();
    hide();
    expect(sendBeacon).not.toHaveBeenCalled();
  });
});
