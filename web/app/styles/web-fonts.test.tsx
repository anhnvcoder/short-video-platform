import { render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WebFonts, webFontsAttribute } from "./web-fonts";

// next/font runs only in a Next build; the test gets the family and weights it would give.
vi.mock("./fonts", () => ({
  beVietnamPro: { style: { fontFamily: "'beVietnamPro', 'beVietnamPro Fallback'" } },
  beVietnamProWeights: ["400", "500", "600", "700"],
}));

// jsdom has no FontFaceSet: each load the component asks for waits until the test settles it.
const pending: { font: string; resolve: () => void; reject: (error: Error) => void }[] = [];
const load = vi.fn(
  (font: string) =>
    new Promise<void>((resolve, reject) => {
      pending.push({ font, resolve, reject });
    }),
);

let state: DocumentReadyState = "loading";

function fireLoad() {
  state = "complete";
  window.dispatchEvent(new Event("load"));
}

const switched = () => document.documentElement.hasAttribute(webFontsAttribute);

beforeEach(() => {
  pending.length = 0;
  load.mockClear();
  state = "loading";
  vi.spyOn(document, "readyState", "get").mockImplementation(() => state);
  Object.defineProperty(document, "fonts", { value: { load }, configurable: true });
});

afterEach(() => {
  vi.restoreAllMocks();
  document.documentElement.removeAttribute(webFontsAttribute);
});

describe("WebFonts", () => {
  it("asks for no font before the page's load event", async () => {
    render(<WebFonts />);
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(load).not.toHaveBeenCalled();
    expect(switched()).toBe(false);
  });

  it("loads the four weights after the load event and switches the text once all are in", async () => {
    render(<WebFonts />);
    fireLoad();
    expect(pending.map((entry) => entry.font)).toEqual([
      "400 1em 'beVietnamPro', 'beVietnamPro Fallback'",
      "500 1em 'beVietnamPro', 'beVietnamPro Fallback'",
      "600 1em 'beVietnamPro', 'beVietnamPro Fallback'",
      "700 1em 'beVietnamPro', 'beVietnamPro Fallback'",
    ]);
    for (const entry of pending.slice(0, 3)) {
      entry.resolve();
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
    // One weight still on its way: no text switches yet, so the page reflows only once.
    expect(switched()).toBe(false);
    pending[3]!.resolve();
    await vi.waitFor(() => expect(switched()).toBe(true));
  });

  it("starts at once when the page has already loaded", async () => {
    state = "complete";
    render(<WebFonts />);
    expect(load).toHaveBeenCalledTimes(4);
    for (const entry of pending) {
      entry.resolve();
    }
    await vi.waitFor(() => expect(switched()).toBe(true));
  });

  it("switches even when a weight fails to load", async () => {
    render(<WebFonts />);
    fireLoad();
    pending[0]!.reject(new Error("NetworkError"));
    for (const entry of pending.slice(1)) {
      entry.resolve();
    }
    await vi.waitFor(() => expect(switched()).toBe(true));
  });

  it("does nothing once unmounted before the load event", async () => {
    const { unmount } = render(<WebFonts />);
    unmount();
    fireLoad();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(load).not.toHaveBeenCalled();
    expect(switched()).toBe(false);
  });

  it("does not switch when unmounted while the fonts load", async () => {
    const { unmount } = render(<WebFonts />);
    fireLoad();
    unmount();
    for (const entry of pending) {
      entry.resolve();
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(switched()).toBe(false);
  });
});
