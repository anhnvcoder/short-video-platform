import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { HlsClass } from "./hls-loader";
import { PlayerPool, poolSize, slotOf, windowIndexes, type PoolCallbacks, type PoolSource } from "./player-pool";

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
const loader = () => Promise.resolve(FakeHls as unknown as HlsClass);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function sources(count: number, origin = mediaOrigin): PoolSource[] {
  return Array.from({ length: count }, (_, index) => ({
    index,
    playlistUrl: `${origin}/media/hls/${index}/master.m3u8`,
    posterUrl: `${origin}/media/thumbs/${index}.jpg`,
  }));
}

function hosts(count: number): HTMLElement[] {
  return Array.from({ length: count }, () => document.body.appendChild(document.createElement("div")));
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
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
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
    expect(video?.poster).toBe(`${mediaOrigin}/media/thumbs/0.jpg`);
    expect(live()).toHaveLength(1);
    expect(live()[0]?.source).toBe(`${mediaOrigin}/media/hls/0/master.m3u8`);
    expect(live()[0]?.config).not.toHaveProperty("xhrSetup");
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledTimes(1);
  });

  it("with two items, gives both a player and plays only the current one", async () => {
    const pool = new PlayerPool(mediaOrigin, callbacks(), loader);
    const elements = hosts(2);
    pool.sync(1, sources(2), (index) => elements[index] ?? null, true);
    await settle();
    expect(elements.map((host) => host.querySelectorAll("video").length)).toEqual([1, 1]);
    expect(live()).toHaveLength(2);
    const play = vi.mocked(HTMLMediaElement.prototype.play);
    expect(play).toHaveBeenCalledTimes(1);
    expect(play.mock.contexts[0]).toBe(elements[1]?.querySelector("video"));
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
    const [first, second, third] = FakeHls.instances;
    pool.sync(2, list, (index) => elements[index] ?? null, true);
    await settle();
    expect(first?.destroyed).toBe(true);
    expect(second?.destroyed).toBe(false);
    expect(third?.destroyed).toBe(false);
    expect(live()).toHaveLength(3);
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

  it("refuses a playlist or poster outside the media origin", async () => {
    const events = callbacks();
    const pool = new PlayerPool(mediaOrigin, events, loader);
    const [host] = hosts(1);
    pool.sync(0, sources(1, "https://evil.example"), () => host ?? null, true);
    await settle();
    expect(events.onState).toHaveBeenLastCalledWith(0, "error");
    expect(FakeHls.instances).toHaveLength(0);
    expect(host?.querySelector("video")?.hasAttribute("poster")).toBe(false);
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
  });

  it("shows a playback error when hls.js cannot be loaded", async () => {
    const events = callbacks();
    const pool = new PlayerPool(mediaOrigin, events, () => Promise.reject(new Error("chunk failed")));
    const [host] = hosts(1);
    pool.sync(0, sources(1), () => host ?? null, true);
    await settle();
    expect(events.onState).toHaveBeenLastCalledWith(0, "error");
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
    expect(events.onForcedMute).toHaveBeenCalledTimes(1);
    expect(host?.querySelector("video")?.muted).toBe(true);
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalledTimes(2);
  });
});
