import { handleClientError } from "@/features/monitoring/reporter";
import { loadHls, type HlsClass, type HlsConfig, type HlsInstance } from "./hls-loader";
import { isMediaUrl } from "./media-url";

// A fixed pool of three <video> elements, each with at most one hls.js instance, for the previous, current and next
// item of the feed. Moving through the feed changes a slot's source and moves
// its element into the item's host; it never creates or drops a <video>: WebKit grows memory when media elements come
// and go (WebKit bug 216820), and each live hls.js instance holds a MediaSource and buffers.
//
// Three consecutive indexes have three different remainders modulo 3, so item i always uses slot i % 3 and a slot is
// never wanted by two items of the window at once.
//
// The current item loads first: a neighbour gets its source only once the current item's video can play (or failed),
// so its playlist and segments never compete with the current item's first segment and poster on a slow link.

export const poolSize = 3;

export type PlaybackState = "loading" | "playing" | "paused" | "buffering" | "error";

export interface PoolSource {
  index: number;
  playlistUrl: string;
  posterUrl: string | null;
}

export interface PoolCallbacks {
  onState(index: number, state: PlaybackState): void;
  // Every `timeupdate`, for the progress bar and the view counter.
  onTime(index: number, video: HTMLVideoElement): void;
  // A seek started or ended: the time across it is not playback.
  onSeek(index: number): void;
  // The browser refused to play with sound outside a user gesture; the pool muted every video to play.
  onForcedMute(): void;
}

// Indexes of the items that hold a slot: the current one and its neighbours.
export function windowIndexes(current: number, count: number): number[] {
  return [current - 1, current, current + 1].filter((index) => index >= 0 && index < count);
}

export function slotOf(index: number): number {
  return index % poolSize;
}

const hlsConfig: Partial<HlsConfig> = {
  // The transmuxer runs in hls.js's own worker file, served as a static asset of the build. The ES module builds carry
  // no inlined worker: without workerPath, hls.js demuxes and remuxes every segment on the main thread, one long task
  // per segment while the page is still hydrating. A worker that fails to start makes hls.js fall back to that inline
  // path by itself (a non-fatal error), so playback does not depend on it.
  workerPath: new URL("hls.js/dist/hls.worker.js", import.meta.url).href,
  // No level above what the element shows: a phone does not fetch 1080p for a 390 px wide column.
  capLevelToPlayerSize: true,
  // The first segment comes from the lowest level, the quickest to arrive; the bandwidth it measures lets hls.js move
  // up from the next segment on.
  startLevel: 0,
  // Short clips: a few seconds ahead is enough, and three instances buffer at once. hls.js stretches maxBufferLength to
  // what maxBufferSize holds at the level's bitrate (8 * size / bitrate; the 60 MB default is a whole clip), up to
  // maxMaxBufferLength (600 s by default): both are kept small so no instance downloads the whole clip ahead.
  maxBufferLength: 10,
  maxBufferSize: 2 * 1000 * 1000,
  maxMaxBufferLength: 20,
  backBufferLength: 10,
  // The playlist and segments are public objects of the media origin: hls.js's XHR loader sends them without
  // credentials (withCredentials stays false) and no xhrSetup adds a header or a cookie.
};

interface Slot {
  video: HTMLVideoElement;
  hls: HlsInstance | null;
  index: number | null;
  source: PoolSource | null;
  host: HTMLElement | null;
  // Bumped on every change of source, so an attach still waiting for hls.js to load gives up when it is stale.
  generation: number;
  // The source can play (canplay or playing) or failed: when this slot holds the current item, its neighbours may load.
  started: boolean;
}

export class PlayerPool {
  private readonly slots: Slot[];
  private current = -1;
  private shouldPlay = false;
  private muted = true;
  // The last sync's list and host lookup, used again when the current item starts and its neighbours may load.
  private sources: readonly PoolSource[] = [];
  private hostFor: (index: number) => HTMLElement | null = () => null;

  constructor(
    private readonly mediaOrigin: string,
    private readonly callbacks: PoolCallbacks,
    private readonly hlsLoader: () => Promise<HlsClass> = loadHls,
  ) {
    this.slots = Array.from({ length: poolSize }, () => this.createSlot());
  }

  // Number of hls.js instances alive; never more than the pool size.
  get liveInstances(): number {
    return this.slots.filter((slot) => slot.hls !== null).length;
  }

  // Gives the window around `current` its slots and plays the current item when `shouldPlay` (not paused by the user,
  // page visible). `hostFor` returns the element of an item the video goes into.
  sync(
    current: number,
    sources: readonly PoolSource[],
    hostFor: (index: number) => HTMLElement | null,
    shouldPlay: boolean,
  ): void {
    this.current = current;
    this.shouldPlay = shouldPlay;
    this.sources = sources;
    this.hostFor = hostFor;
    this.update();
  }

  private update(): void {
    const { current, sources, hostFor } = this;
    const wanted = windowIndexes(current, sources.length);
    // On the item after the last video nothing plays, so the last video has nothing to wait for.
    const lead = this.slots[slotOf(current)];
    const leadStarted = current >= sources.length || (lead?.index === current && lead.started);
    this.slots.forEach((slot, slotIndex) => {
      const index = wanted.find((candidate) => slotOf(candidate) === slotIndex);
      const source = index === undefined ? undefined : sources[index];
      const host = index === undefined ? null : hostFor(index);
      if (!source || !host) {
        this.release(slot);
        return;
      }
      if (slot.index !== source.index || slot.source?.playlistUrl !== source.playlistUrl) {
        this.release(slot);
        // Plays once the source is attached. A neighbour waits for the current item to start (update runs again then).
        if (source.index === current || leadStarted) {
          void this.attach(slot, source, host);
        }
        return;
      }
      if (slot.host !== host) {
        // The item's element was replaced; the video follows it without reloading.
        slot.host = host;
        host.append(slot.video);
      }
      this.applyPlayback(slot);
    });
  }

  setMuted(muted: boolean): void {
    this.muted = muted;
    for (const slot of this.slots) {
      slot.video.muted = muted;
    }
  }

  // Loads the item's source again after a playback error.
  retry(index: number): void {
    const slot = this.slots[slotOf(index)];
    if (!slot || slot.index !== index || !slot.source || !slot.host) {
      return;
    }
    const { source, host } = slot;
    this.release(slot);
    void this.attach(slot, source, host);
  }

  destroy(): void {
    this.sources = [];
    for (const slot of this.slots) {
      this.release(slot);
    }
  }

  private createSlot(): Slot {
    const video = document.createElement("video");
    // Autoplay is allowed only muted; the first tap turns the sound on. playsinline keeps iOS from going full screen.
    video.muted = true;
    video.defaultMuted = true;
    video.playsInline = true;
    video.setAttribute("playsinline", "");
    video.loop = true;
    video.preload = "metadata";
    video.className = "absolute inset-0 size-full object-cover";
    const slot: Slot = { video, hls: null, index: null, source: null, host: null, generation: 0, started: false };
    const report = (state: PlaybackState) => () => {
      if (slot.index !== null) {
        this.callbacks.onState(slot.index, state);
      }
    };
    video.addEventListener("canplay", () => {
      if (!slot.started) {
        // For the current item this runs update, which plays it.
        this.markStarted(slot);
      } else if (slot.index !== null) {
        // An hls.js source waits for this before it plays (applyPlayback), also after it started once.
        this.applyPlayback(slot);
      }
    });
    video.addEventListener("playing", () => {
      video.dataset.state = "playing";
      report("playing")();
      this.markStarted(slot);
    });
    video.addEventListener("pause", () => {
      video.dataset.state = "paused";
      report("paused")();
    });
    video.addEventListener("waiting", () => {
      video.dataset.state = "buffering";
      report("buffering")();
    });
    video.addEventListener("error", () => {
      // Only the native HLS path reports through the element; hls.js reports through its ERROR event.
      if (slot.hls === null && slot.source !== null) {
        video.dataset.state = "error";
        report("error")();
      }
    });
    video.addEventListener("timeupdate", () => {
      if (slot.index !== null) {
        this.callbacks.onTime(slot.index, video);
      }
    });
    const seek = () => {
      if (slot.index !== null) {
        this.callbacks.onSeek(slot.index);
      }
    };
    video.addEventListener("seeking", seek);
    video.addEventListener("seeked", seek);
    return slot;
  }

  private async attach(slot: Slot, source: PoolSource, host: HTMLElement): Promise<void> {
    const generation = ++slot.generation;
    const { video } = slot;
    slot.index = source.index;
    slot.source = source;
    slot.host = host;
    video.muted = this.muted;
    if (source.posterUrl && isMediaUrl(source.posterUrl, this.mediaOrigin)) {
      video.poster = source.posterUrl;
    } else {
      video.removeAttribute("poster");
    }
    host.append(video);
    this.callbacks.onState(source.index, "loading");

    if (!isMediaUrl(source.playlistUrl, this.mediaOrigin)) {
      this.fail(slot);
      return;
    }
    let Hls: HlsClass;
    try {
      Hls = await this.hlsLoader();
    } catch (error) {
      if (slot.generation === generation) {
        // No error boundary sees this rejection: hls.js's chunk of another build reloads the page once, anything else
        // is reported here. The video shows its error either way.
        handleClientError(error);
        this.fail(slot);
      }
      return;
    }
    if (slot.generation !== generation) {
      return;
    }
    // MediaSource, or ManagedMediaSource on iOS 17.1+: hls.js. Only without either does the browser play HLS itself.
    if (!Hls.isSupported()) {
      video.src = source.playlistUrl;
      this.applyPlayback(slot);
      return;
    }
    const hls = new Hls(hlsConfig);
    slot.hls = hls;
    hls.on(Hls.Events.ERROR, (_event, data) => {
      // hls.js retries what it can by itself; a fatal error ends this instance, so a broken segment never loops.
      if (data.fatal && slot.hls === hls) {
        this.fail(slot);
      }
    });
    hls.once(Hls.Events.MEDIA_ATTACHED, () => {
      if (slot.hls === hls) {
        this.applyPlayback(slot);
      }
    });
    hls.loadSource(source.playlistUrl);
    hls.attachMedia(video);
  }

  private fail(slot: Slot): void {
    slot.hls?.destroy();
    slot.hls = null;
    slot.video.dataset.state = "error";
    if (slot.index !== null) {
      this.callbacks.onState(slot.index, "error");
    }
    // A broken current video does not hold its neighbours back.
    this.markStarted(slot);
  }

  private markStarted(slot: Slot): void {
    if (slot.started || slot.index === null) {
      return;
    }
    slot.started = true;
    if (slot.index === this.current) {
      this.update();
    }
  }

  private applyPlayback(slot: Slot): void {
    const { video } = slot;
    if (slot.index !== this.current || !this.shouldPlay) {
      if (!video.paused) {
        video.pause();
      }
      return;
    }
    if (slot.video.dataset.state === "error" || !video.paused) {
      return;
    }
    // With hls.js, play only once the element can play (canplay calls this again). Playing before any data makes the
    // element wait at 0 s while the first segment starts a little later (0.07 s for the media worker's MPEG-TS), so
    // hls.js seeks over that gap during playback; WebKit on Linux (GStreamer) under load then never ends the seek and the
    // video stays buffering with its data in hand. hls.js loads segments without play(); the browser's own HLS player
    // (no MediaSource) does not, so it is told to play at once.
    if (slot.hls !== null && video.readyState < HTMLMediaElement.HAVE_FUTURE_DATA) {
      return;
    }
    const playing = video.play();
    // Old engines return nothing; the promise is always handled so a refused play is never an unhandled rejection.
    void playing?.catch((error: unknown) => {
      if (error instanceof DOMException && error.name === "NotAllowedError" && !video.muted) {
        // Sound needs a gesture the user has not made in this page yet: play muted instead of not at all.
        this.setMuted(true);
        this.callbacks.onForcedMute();
        if (slot.index === this.current && this.shouldPlay) {
          void video.play()?.catch(() => {
            // Still refused (low power mode, data saver): the play button stays.
          });
        }
      } else if (slot.index !== null && !(error instanceof DOMException && error.name === "AbortError")) {
        this.callbacks.onState(slot.index, "paused");
      }
    });
  }

  private release(slot: Slot): void {
    slot.generation++;
    slot.hls?.destroy();
    slot.hls = null;
    const { video } = slot;
    if (slot.source !== null) {
      video.pause();
      video.removeAttribute("src");
      video.removeAttribute("poster");
      // Drops the decoder and buffered data of the old source.
      video.load();
    }
    delete video.dataset.state;
    video.remove();
    slot.started = false;
    slot.index = null;
    slot.source = null;
    slot.host = null;
  }
}
