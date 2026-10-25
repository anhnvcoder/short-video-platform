import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleClientError } from "@/features/monitoring/reporter";
import type { HlsClass } from "./hls-loader";
import { PlayerPool, poolSize, slotOf, windowIndexes, type PoolCallbacks, type PoolSource } from "./player-pool";

// What the pool does with a loader error is the reporter's business: reload once on a build skew, else report.
vi.mock("@/features/monitoring/reporter", () => ({ handleClientError: vi.fn() }));

const mediaOrigin = "http://127.0.0.1:9000";

type Handler = (event: string, data: { fatal?: boolean }) => void;

// Stands in for hls.js: records what the pool does with each instance.
class FakeHls {
  static instances: FakeHls[] = [];
  static supported = true;
  static Events = { ERROR: "hlsError", MEDIA_ATTACHED: "hlsMediaAttached" };
  static isSupported() {
    return FakeHls.supported;
  }

  readonly handlers = new Map<string, Handler[]>();
  destroyed = false;
  source: string | null = null;
  media: HTMLVideoElement | null = null;

  constructor(readonly config: Record<string, unknown>) {
    FakeHls.instances.push(this);
  }
  on(event: string, handler: Handler) {
    this.handlers.set(event, [...(this.handlers.get(event) ?? []), handler]);
  }
  once(event: string, handler: Handler) {
    this.on(event, handler);
  }
  loadSource(url: string) {
    this.source = url;
  }
  attachMedia(media: HTMLVideoElement) {
    this.media = media;
    this.emit(FakeHls.Events.MEDIA_ATTACHED, {});
  }
  destroy() {
    this.destroyed = true;
  }
  emit(event: string, data: { fatal?: boolean }) {
    for (const handler of this.handlers.get(event) ?? []) {
      handler(event, data);
    }
  }
}

const live = () => FakeHls.instances.filter((instance) => !instance.destroyed);
// Sorted, so a test does not depend on the order the pool creates instances in.
const liveSources = () =>
  live()
    .map((instance) => instance.source)
    .sort();
const instanceOf = (source: PoolSource | undefined) =>
  FakeHls.instances.find((instance) => instance.source === source?.playlistUrl);
const loader = () => Promise.resolve(FakeHls as unknown as HlsClass);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function sources(count: number, origin = mediaOrigin): PoolSource[] {
  return Array.from({ length: count }, (_, index) => ({
    index,
    playlistUrl: `${origin}/media/hls/${index}/master.m3u8`,
  }));
}

function hosts(count: number): HTMLElement[] {
  return Array.from({ length: count }, () => document.body.appendChild(document.createElement("div")));
}

// The video of a host can play: hls.js appended its first data (canplay) or playback began (playing). jsdom's element
// stays at HAVE_NOTHING, so the element is given the ready state a browser reports by then.
function start(host: HTMLElement | undefined, event: "canplay" | "playing" = "canplay") {
  const video = host?.querySelector("video");
  if (video) {
    Object.defineProperty(video, "readyState", { configurable: true, value: HTMLMediaElement.HAVE_ENOUGH_DATA });
    video.dispatchEvent(new Event(event));
  }
}

function callbacks() {
  return {
    onState: vi.fn<PoolCallbacks["onState"]>(),
    onTime: vi.fn<PoolCallbacks["onTime"]>(),
    onSeek: vi.fn<PoolCallbacks["onSeek"]>(),
    onForcedMute: vi.fn<PoolCallbacks["onForcedMute"]>(),
  };
}

beforeEach(() => {
  FakeHls.instances = [];
  FakeHls.supported = true;
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  // load() drops the old source, as in a browser: the element has no data again.
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(function (this: HTMLMediaElement) {
    Reflect.deleteProperty(this, "readyState");
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  document.body.replaceChildren();
});

describe("windowIndexes", () => {
  it("is the current item and its neighbours, inside the list", () => {
    expect(windowIndexes(0, 1)).toEqual([0]);
    expect(windowIndexes(0, 2)).toEqual([0, 1]);
    expect(windowIndexes(1, 2)).toEqual([0, 1]);
    expect(windowIndexes(0, 10)).toEqual([0, 1]);
    expect(windowIndexes(5, 10)).toEqual([4, 5, 6]);
    expect(windowIndexes(9, 10)).toEqual([8, 9]);
    // The item after the last video: only the last video keeps a slot.
    expect(windowIndexes(10, 10)).toEqual([9]);
    expect(windowIndexes(0, 0)).toEqual([]);
  });

  it("never gives two items of a window the same slot", () => {
    for (let current = 0; current < 50; current++) {
      const slots = windowIndexes(current, 50).map(slotOf);
      expect(new Set(slots).size).toBe(slots.length);
      expect(slots.every((slot) => slot >= 0 && slot < poolSize)).toBe(true);
    }
  });
});

describe("PlayerPool", () => {
  it("plays a single item", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    const video = host?.querySelector("video");
    expect(video).toBeTruthy();
    expect(video?.muted).toBe(true);
    expect(video?.playsInline).toBe(true);
    expect(video?.getAttribute("crossorigin")).toBeNull();
    // The item's own <img> is the poster: the <video> paints nothing until its first frame.
    expect(video?.hasAttribute("poster")).toBe(false);
    expect(live()).toHaveLength(1);
    expect(live()[0]?.source).toBe(`${mediaOrigin}/media/hls/0/master.m3u8`);
    expect(live()[0]?.config).not.toHaveProperty("xhrSetup");
    start(host);
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledTimes(1);
  });

  it("plays an hls.js source only once it can play", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    // Attached, no data yet: playing now would make hls.js seek over the gap before the first segment during playback,
    // a seek WebKit on Linux can leave unfinished.
    expect(live()[0]?.media).toBe(host?.querySelector("video"));
    expect(HTMLMediaElement.prototype.play).not.toHaveBeenCalled();
    start(host);
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledTimes(1);
  });

  it("with two items, gives both a player and plays only the current one", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(2);
    pool.sync(1, sources(2), (index) => elements[index] ?? null, true);
    await settle();
    start(elements[1]);
    await settle();
    expect(elements.map((host) => host.querySelectorAll("video").length)).toEqual([1, 1]);
    expect(live()).toHaveLength(2);
    const play = vi.mocked(HTMLMediaElement.prototype.play);
    // jsdom's stubbed play() leaves the element paused, so the sync after canplay asks again; a browser would not.
    expect(play).toHaveBeenCalled();
    expect(new Set(play.mock.contexts)).toEqual(new Set([elements[1]?.querySelector("video")]));
  });

  it("does not play when playback is off (paused by the user, page hidden)", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(3);
    pool.sync(1, sources(3), (index) => elements[index] ?? null, false);
    await settle();
    expect(HTMLMediaElement.prototype.play).not.toHaveBeenCalled();
  });

  it("reuses three <video> elements and keeps at most three hls.js instances while scrolling fast", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(20);
    const list = sources(20);
    const seen = new Set<HTMLVideoElement>();
    // Faster than hls.js loads: no sync waits for the previous one.
    for (let current = 0; current < 20; current++) {
      pool.sync(current, list, (index) => elements[index] ?? null, true);
      document.querySelectorAll("video").forEach((video) => seen.add(video));
      expect(pool.liveInstances).toBeLessThanOrEqual(poolSize);
    }
    await settle();
    expect(seen.size).toBe(poolSize);
    // Window [18, 19]: two live instances, every other one destroyed, and no stale load created one late.
    expect(live()).toHaveLength(2);
    expect(live().map((instance) => instance.source)).toEqual(
      expect.arrayContaining([list[18]?.playlistUrl, list[19]?.playlistUrl]),
    );
    expect(document.querySelectorAll("video")).toHaveLength(2);
    expect(elements[19]?.querySelector("video")).toBeTruthy();
    expect(elements[17]?.querySelector("video")).toBeNull();
  });

  it("moving by one keeps the instances of the items that stay in the window", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(5);
    const list = sources(5);
    pool.sync(1, list, (index) => elements[index] ?? null, true);
    await settle();
    start(elements[1]);
    await settle();
    const [first, second, third] = [0, 1, 2].map((index) => instanceOf(list[index]));
    expect(live()).toHaveLength(3);
    pool.sync(2, list, (index) => elements[index] ?? null, true);
    await settle();
    expect(first?.destroyed).toBe(true);
    expect(second?.destroyed).toBe(false);
    expect(third?.destroyed).toBe(false);
    // Item 3 waits for item 2, now the current one, to start.
    expect(liveSources()).toEqual([list[1]?.playlistUrl, list[2]?.playlistUrl]);
    start(elements[2], "playing");
    await settle();
    expect(liveSources()).toEqual([list[1]?.playlistUrl, list[2]?.playlistUrl, list[3]?.playlistUrl]);
    expect(elements[3]?.querySelector("video")).toBeTruthy();
  });

  it("caps every instance's start level and buffer, so no player downloads a whole clip ahead", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(3);
    pool.sync(1, sources(3), (index) => elements[index] ?? null, true);
    await settle();
    start(elements[1]);
    await settle();
    expect(live()).toHaveLength(3);
    for (const instance of live()) {
      expect(instance.config).toMatchObject({
        capLevelToPlayerSize: true,
        startLevel: 0,
        maxBufferLength: 10,
        maxBufferSize: 2_000_000,
        maxMaxBufferLength: 20,
      });
      // What hls.js 1.7 buffers ahead at a level's bitrate: min(max(8 * size / bitrate, length), max length) seconds.
      // On the media-worker ladder: 360p (0.8 Mbit/s) stretches to the 20 s ceiling, 2 MB; 720p (2.5 Mbit/s) and 1080p
      // (5 Mbit/s, picked on a wide desktop player) stay at the 10 s floor, about 3.1 MB and 6.3 MB. A 60 s 720p clip is
      // about 19 MB.
      const { maxBufferLength, maxBufferSize, maxMaxBufferLength } = instance.config as Record<
        "maxBufferLength" | "maxBufferSize" | "maxMaxBufferLength",
        number
      >;
      for (const [bitrate, bound] of [
        [800_000, 4_000_000],
        [2_500_000, 4_000_000],
        [5_000_000, 6_500_000],
      ] as const) {
        const seconds = Math.min(Math.max((8 * maxBufferSize) / bitrate, maxBufferLength), maxMaxBufferLength);
        expect((seconds * bitrate) / 8).toBeLessThanOrEqual(bound);
      }
    }
  });

  it("gives every instance hls.js's worker file, so segments are transmuxed off the main thread", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(2);
    pool.sync(0, sources(2), (index) => elements[index] ?? null, true);
    await settle();
    start(elements[0]);
    await settle();
    expect(live()).toHaveLength(2);
    for (const instance of live()) {
      expect(instance.config.workerPath).toMatch(/\/hls\.worker[^/]*\.js$/);
    }
  });

  it("loads the neighbours only once the current video starts", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(3);
    const list = sources(3);
    pool.sync(1, list, (index) => elements[index] ?? null, true);
    await settle();
    expect(liveSources()).toEqual([list[1]?.playlistUrl]);
    expect(elements[0]?.querySelector("video")).toBeNull();
    expect(elements[2]?.querySelector("video")).toBeNull();
    // A sync for another reason (pause, a new page) does not load them early either.
    pool.sync(1, list, (index) => elements[index] ?? null, false);
    await settle();
    expect(live()).toHaveLength(1);

    start(elements[1], "playing");
    await settle();
    expect(liveSources()).toEqual(list.map((source) => source.playlistUrl));
    // A later event of the same video loads nothing more.
    start(elements[1], "canplay");
    await settle();
    expect(FakeHls.instances).toHaveLength(3);
  });

  it("a neighbour that started before it became current lets the next one load at once", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(5);
    const list = sources(5);
    pool.sync(1, list, (index) => elements[index] ?? null, true);
    await settle();
    start(elements[1]);
    await settle();
    // Item 2 buffered its first segment while a neighbour: that alone loads nothing.
    start(elements[2]);
    await settle();
    expect(live()).toHaveLength(3);
    pool.sync(2, list, (index) => elements[index] ?? null, true);
    await settle();
    expect(liveSources()).toEqual([list[1]?.playlistUrl, list[2]?.playlistUrl, list[3]?.playlistUrl]);
    // It can play already, so it plays without waiting for another canplay.
    expect(vi.mocked(HTMLMediaElement.prototype.play).mock.contexts).toContain(elements[2]?.querySelector("video"));
  });

  it("a current video that fails does not hold its neighbours back", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(3);
    const list = sources(3);
    pool.sync(1, list, (index) => elements[index] ?? null, true);
    await settle();
    instanceOf(list[1])?.emit(FakeHls.Events.ERROR, { fatal: true });
    await settle();
    expect(liveSources()).toEqual([list[0]?.playlistUrl, list[2]?.playlistUrl]);
  });

  it("on the item after the last video, the last video loads without waiting", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(2);
    const list = sources(2);
    pool.sync(2, list, (index) => elements[index] ?? null, true);
    await settle();
    expect(liveSources()).toEqual([list[1]?.playlistUrl]);
    expect(HTMLMediaElement.prototype.play).not.toHaveBeenCalled();
  });

  it("a video event after destroy() loads nothing", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(3);
    pool.sync(1, sources(3), (index) => elements[index] ?? null, true);
    await settle();
    const video = elements[1]?.querySelector("video");
    pool.destroy();
    video?.dispatchEvent(new Event("canplay"));
    await settle();
    expect(FakeHls.instances).toHaveLength(1);
    expect(live()).toHaveLength(0);
  });

  it("destroy() releases every instance and takes the videos out of the page", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(3);
    pool.sync(1, sources(3), (index) => elements[index] ?? null, true);
    await settle();
    pool.destroy();
    expect(live()).toHaveLength(0);
    expect(document.querySelectorAll("video")).toHaveLength(0);
  });

  it("a destroy while hls.js is still loading creates no instance", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    pool.destroy();
    await settle();
    expect(FakeHls.instances).toHaveLength(0);
  });

  it("a fatal error shows the error state once and loads nothing more until retry", async () => {
    const events = callbacks();
    const pool = new PlayerPool(mediaOrigin, events, loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    const instance = FakeHls.instances[0];
    instance?.emit(FakeHls.Events.ERROR, { fatal: false });
    expect(events.onState).not.toHaveBeenCalledWith(0, "error");
    instance?.emit(FakeHls.Events.ERROR, { fatal: true });
    expect(events.onState).toHaveBeenLastCalledWith(0, "error");
    expect(instance?.destroyed).toBe(true);
    expect(host?.querySelector("video")?.dataset.state).toBe("error");
    await settle();
    expect(FakeHls.instances).toHaveLength(1);

    pool.retry(0);
    await settle();
    expect(FakeHls.instances).toHaveLength(2);
    expect(live()).toHaveLength(1);
    expect(events.onState).toHaveBeenCalledWith(0, "loading");
  });

  it("refuses a playlist outside the media origin", async () => {
    const events = callbacks();
    const pool = new PlayerPool(mediaOrigin, events, loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1, "https://evil.example"), () => host ?? null, true);
    await settle();
    expect(events.onState).toHaveBeenLastCalledWith(0, "error");
    expect(FakeHls.instances).toHaveLength(0);
    expect(host?.querySelector("video")?.getAttribute("src")).toBeNull();
  });

  it("plays HLS natively only when there is no MediaSource", async () => {
    FakeHls.supported = false;
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    expect(FakeHls.instances).toHaveLength(0);
    expect(host?.querySelector("video")?.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/0/master.m3u8`);
    // The browser's own HLS player loads little before play(), so it is told to play at once.
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledTimes(1);
  });

  it("shows a playback error when hls.js cannot be loaded, after handing the error on", async () => {
    vi.mocked(handleClientError).mockClear();
    const events = callbacks();
    // What Turbopack's runtime throws when hls.js's chunk is gone (a page of another build).
    const error = Object.assign(new Error("Failed to load chunk /_next/static/chunks/hls.js from module 7: 404"), {
      name: "ChunkLoadError",
    });
    const pool = new PlayerPool(mediaOrigin, events, () => Promise.reject(error));
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    expect(handleClientError).toHaveBeenCalledExactlyOnceWith(error);
    expect(events.onState).toHaveBeenLastCalledWith(0, "error");
    expect(host?.querySelector("video")?.dataset.state).toBe("error");
  });

  it("does not report a loader error of a source it has already left", async () => {
    vi.mocked(handleClientError).mockClear();
    let reject: (error: Error) => void = () => {};
    const pool = new PlayerPool(
      mediaOrigin,
      callbacks(),
      () => new Promise<HlsClass>((_resolve, rejectLoad) => (reject = rejectLoad)),
    );
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    pool.destroy();
    reject(new Error("Failed to load chunk"));
    await settle();
    expect(handleClientError).not.toHaveBeenCalled();
  });

  it("marks the playing element with data-state=playing and reports it", async () => {
    const events = callbacks();
    const pool = new PlayerPool(mediaOrigin, events, loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    const video = host?.querySelector("video");
    video?.dispatchEvent(new Event("playing"));
    expect(video?.dataset.state).toBe("playing");
    expect(events.onState).toHaveBeenLastCalledWith(0, "playing");
    video?.dispatchEvent(new Event("seeking"));
    expect(events.onSeek).toHaveBeenCalledWith(0);
  });

  it("plays muted when the browser refuses sound outside a gesture", async () => {
    const events = callbacks();
    const pool = new PlayerPool(mediaOrigin, events, loader);
    pool.setMuted(false);
    vi.mocked(HTMLMediaElement.prototype.play)
      .mockRejectedValueOnce(new DOMException("needs a gesture", "NotAllowedError"))
      .mockResolvedValue(undefined);
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    start(host);
    await settle();
    expect(events.onForcedMute).toHaveBeenCalledTimes(1);
    expect(host?.querySelector("video")?.muted).toBe(true);
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledTimes(2);
  });
});
