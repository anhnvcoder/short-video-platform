import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { checkFile, checkTitle, maxUploadBytes, readDuration, titleLength } from "./file-checks";

const file = (name: string, type: string, size: number) => ({ name, type, size });

describe("checkFile", () => {
  it("takes a video of exactly 500 MiB and refuses one byte more", () => {
    expect(checkFile(file("clip.mp4", "video/mp4", maxUploadBytes))).toEqual({ ok: true, contentType: "video/mp4" });
    expect(checkFile(file("clip.mp4", "video/mp4", maxUploadBytes + 1))).toEqual({ ok: false, problem: "too-large" });
  });

  it("refuses an empty file, which the gateway would refuse too (size_bytes >= 1)", () => {
    expect(checkFile(file("clip.mp4", "video/mp4", 0))).toEqual({ ok: false, problem: "empty" });
  });

  it("refuses a file whose type is not video/*", () => {
    expect(checkFile(file("bao-cao.pdf", "application/pdf", 1000))).toEqual({ ok: false, problem: "not-video" });
    expect(checkFile(file("song.mp4", "audio/mp4", 1000))).toEqual({ ok: false, problem: "not-video" });
  });

  it("guesses the type from the extension when the browser gives none", () => {
    expect(checkFile(file("clip.MP4", "", 10))).toEqual({ ok: true, contentType: "video/mp4" });
    expect(checkFile(file("clip.mov", "", 10))).toEqual({ ok: true, contentType: "video/quicktime" });
    expect(checkFile(file("clip.webm", "", 10))).toEqual({ ok: true, contentType: "video/webm" });
    expect(checkFile(file("clip.mkv", "", 10))).toEqual({ ok: false, problem: "not-video" });
    expect(checkFile(file("clip", "", 10))).toEqual({ ok: false, problem: "not-video" });
  });

  it("keeps the browser's own video type", () => {
    expect(checkFile(file("clip.mkv", "video/x-matroska", 10))).toEqual({ ok: true, contentType: "video/x-matroska" });
  });
});

describe("checkTitle", () => {
  it("counts characters after trimming, as video-service does", () => {
    expect(checkTitle("   ")).toBe("required");
    expect(checkTitle(` ${"a".repeat(200)} `)).toBeNull();
    expect(checkTitle("a".repeat(201))).toBe("too-long");
    // One emoji is one character, though two UTF-16 units.
    expect(titleLength("😀".repeat(200))).toBe(200);
    expect(checkTitle("😀".repeat(200))).toBeNull();
  });
});

describe("readDuration", () => {
  let created: HTMLVideoElement[];
  const revoke = vi.fn();

  beforeEach(() => {
    created = [];
    const createElement = document.createElement.bind(document);
    vi.spyOn(document, "createElement").mockImplementation((tag: string, options?: ElementCreationOptions) => {
      const element = createElement(tag, options);
      if (element instanceof HTMLVideoElement) {
        created.push(element);
      }
      return element;
    });
    // jsdom has no object URLs.
    URL.createObjectURL = vi.fn(() => "blob:http://localhost/1");
    URL.revokeObjectURL = revoke;
  });

  afterEach(() => {
    vi.restoreAllMocks();
    revoke.mockReset();
    vi.useRealTimers();
  });

  function video(): HTMLVideoElement {
    const element = created[0];
    if (!element) {
      throw new Error("no video element");
    }
    return element;
  }

  it("reads the duration from the metadata only, then revokes the object URL", async () => {
    const result = readDuration(new Blob(["x"]));
    expect(video().preload).toBe("metadata");
    expect(video().getAttribute("src")).toBe("blob:http://localhost/1");
    Object.defineProperty(video(), "duration", { value: 42.5 });
    video().dispatchEvent(new Event("loadedmetadata"));
    await expect(result).resolves.toBe(42.5);
    expect(revoke).toHaveBeenCalledWith("blob:http://localhost/1");
    expect(video().hasAttribute("src")).toBe(false);
  });

  it("answers null for a file the browser cannot decode, so it is still let through", async () => {
    const result = readDuration(new Blob(["x"]));
    video().dispatchEvent(new Event("error"));
    await expect(result).resolves.toBeNull();
    expect(revoke).toHaveBeenCalledTimes(1);
  });

  it("answers null for an infinite duration", async () => {
    const result = readDuration(new Blob(["x"]));
    Object.defineProperty(video(), "duration", { value: Infinity });
    video().dispatchEvent(new Event("loadedmetadata"));
    await expect(result).resolves.toBeNull();
  });

  it("gives up after 10 s without metadata", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const result = readDuration(new Blob(["x"]));
    await vi.advanceTimersByTimeAsync(10_000);
    await expect(result).resolves.toBeNull();
    expect(revoke).toHaveBeenCalledTimes(1);
  });
});
