import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { useRouter } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Upload, UploadStore } from "@/features/upload/upload-store";
import { messagesFor } from "@/i18n/messages";
import { formatCompact } from "@/lib/format";
import { server } from "@/lib/test/msw-server";
import type { ProfileVideo, ProfileVideoPage } from "./api";
import { MyVideosScreen } from "./my-videos-screen";

vi.mock("next/navigation", () => ({ useRouter: vi.fn() }));

const mediaOrigin = "http://127.0.0.1:9000";
const userId = "0192f0c1-7a3e-7c4b-9d2e-000000000001";
const id = (n: number) => `0192f0c1-0000-7000-8000-${String(n).padStart(12, "0")}`;
const renderedAt = Date.parse("2026-10-22T08:00:00Z");
const router = { replace: vi.fn(), push: vi.fn(), back: vi.fn() };
const t = messagesFor("vi").profile;

function video(n: number, status: ProfileVideo["status"], extra: Partial<ProfileVideo> = {}): ProfileVideo {
  return { video_id: id(n), title: `Video ${n}`, status, created_at: "2026-10-19T08:00:00Z", ...extra };
}

const ready = (n: number, extra: Partial<ProfileVideo> = {}) =>
  video(n, "READY", {
    duration_ms: 58_000,
    published_at: "2026-10-19T08:00:00Z",
    thumbnail_url: `${mediaOrigin}/thumbs/${n}.jpg`,
    view_count: 8300,
    ...extra,
  });

// The video list as the gateway's JSON, which fetchMyVideos cleans.
function apiPage(items: ProfileVideo[], next_cursor = "") {
  return {
    items: items.map(({ view_count, ...item }) => ({
      ...item,
      author_id: userId,
      ...(view_count === undefined ? {} : { stats: { view_count, like_count: 0, liked_by_me: false } }),
    })),
    next_cursor,
  };
}

// GET /api/me/videos: each call gets the next answer, the last one from then on.
function listServer(...answers: (() => Response)[]) {
  const calls: URL[] = [];
  server.use(
    http.get("*/api/me/videos", ({ request }) => {
      calls.push(new URL(request.url));
      const answer = (answers.length > 1 ? answers.shift() : answers[0]) ?? (() => HttpResponse.json(apiPage([])));
      return answer();
    }),
  );
  return calls;
}

function upload(change: Partial<Upload>): Upload {
  return {
    key: "upload-1",
    videoId: null,
    fileName: "clip.mp4",
    title: "Đang tải",
    sizeBytes: 20_000_000,
    status: "sending",
    progress: 0.64,
    bytesPerSecond: 2.1 * 1024 * 1024,
    retries: 0,
    waitingFor: null,
    renewed: false,
    failure: null,
    video: null,
    ...change,
  };
}

// A store holding the uploads a test sets.
function fakeStore(uploads: readonly Upload[] = []) {
  let list = uploads;
  const listeners = new Set<() => void>();
  const store: UploadStore & { set(next: readonly Upload[]): void } = {
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    list: () => list,
    start: vi.fn(),
    cancel: vi.fn(),
    retry: vi.fn(),
    dismiss: vi.fn(),
    set(next) {
      list = next;
      listeners.forEach((listener) => listener());
    },
  };
  return store;
}

function renderScreen({
  initialPage,
  initialRetryAfterSeconds,
  store = fakeStore(),
}: { initialPage?: ProfileVideoPage; initialRetryAfterSeconds?: number; store?: UploadStore } = {}) {
  return render(
    <NextIntlClientProvider locale="vi" messages={{ profile: messagesFor("vi").profile }}>
      <QueryClientProvider client={new QueryClient()}>
        <MyVideosScreen
          userId={userId}
          initialPage={initialPage}
          initialRetryAfterSeconds={initialRetryAfterSeconds}
          mediaOrigin={mediaOrigin}
          renderedAt={renderedAt}
          uploadStore={store}
        />
      </QueryClientProvider>
    </NextIntlClientProvider>,
  );
}

const list = () => screen.getByRole("list", { name: t.my.listLabel });
const rows = () => within(list()).getAllByRole("listitem");

beforeEach(() => {
  vi.mocked(useRouter).mockReturnValue(router as unknown as ReturnType<typeof useRouter>);
  router.replace.mockReset();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("MyVideosScreen", () => {
  it("shows every state with an icon and a word, and what each state allows", () => {
    renderScreen({
      initialPage: {
        items: [video(1, "UPLOADING"), video(2, "PROCESSING"), ready(3), video(4, "FAILED")],
        next_cursor: "",
      },
    });
    const [uploading, processing, done, failed] = rows();

    for (const [row, label] of [
      [uploading, t.status.UPLOADING],
      [processing, t.status.PROCESSING],
      [done, t.status.READY],
      [failed, t.status.FAILED],
    ] as const) {
      // Twice: one badge for small screens, one for the status column of wide screens.
      const badges = within(row!).getAllByText(label);
      expect(badges).toHaveLength(2);
      for (const badge of badges) {
        expect(badge.querySelector("svg")).not.toBeNull();
      }
    }

    // Only a READY video links to its page and shows its thumbnail, length, views and age.
    expect(within(done!).getByRole("link", { name: "Video 3" }).getAttribute("href")).toBe(`/v/${id(3)}`);
    expect(done!.querySelector("img")?.getAttribute("src")).toBe(`${mediaOrigin}/thumbs/3.jpg`);
    const views = t.viewCount.replace("{count}", formatCompact(8300, "vi"));
    // Testing Library reads the no-break space of "8,3 N" as a plain one.
    expect(within(done!).getByText(`0:58 · ${views} · 3 ngày trước`.replace(/\s/g, " "))).toBeTruthy();
    expect(within(processing!).queryByRole("link")).toBeNull();
    expect(processing!.querySelector("img")).toBeNull();

    // A FAILED video offers to upload again.
    expect(within(failed!).getByText(t.my.failed)).toBeTruthy();
    expect(within(failed!).getByRole("link", { name: t.my.reupload }).getAttribute("href")).toBe("/upload");
  });

  it("shows a thumbnail only from the media origin, and the title as text", () => {
    renderScreen({
      initialPage: {
        items: [ready(1, { thumbnail_url: "https://evil.example/t.jpg", title: "<img src=x onerror=alert(1)>" })],
        next_cursor: "",
      },
    });
    const [row] = rows();
    expect(row!.querySelector("img")).toBeNull();
    expect(within(row!).getByRole("link", { name: "<img src=x onerror=alert(1)>" })).toBeTruthy();
  });

  it("names an untitled video", () => {
    renderScreen({ initialPage: { items: [video(1, "PROCESSING", { title: "" })], next_cursor: "" } });
    expect(within(rows()[0]!).getByText(t.untitled)).toBeTruthy();
  });

  it("suggests uploading when the user has no video", () => {
    renderScreen({ initialPage: { items: [], next_cursor: "" } });
    expect(screen.getByText(t.my.empty.title)).toBeTruthy();
    expect(screen.getByRole("link", { name: t.my.empty.action }).getAttribute("href")).toBe("/upload");
  });

  it("loads the next page along next_cursor", async () => {
    const calls = listServer(() => HttpResponse.json(apiPage([ready(2)])));
    renderScreen({ initialPage: { items: [ready(1)], next_cursor: "abc" } });

    fireEvent.click(screen.getByRole("button", { name: t.loadMore }));

    await waitFor(() => expect(rows()).toHaveLength(2));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.pathname).toBe("/api/me/videos");
    expect(Object.fromEntries(calls[0]!.searchParams)).toEqual({ cursor: "abc", page_size: "18" });
    expect(screen.queryByRole("button", { name: t.loadMore })).toBeNull();
  });

  it("fetches the first page itself when the server had none", async () => {
    const calls = listServer(() => HttpResponse.json(apiPage([ready(1)])));
    renderScreen();
    expect(screen.getByRole("status", { name: t.loadingVideos })).toBeTruthy();
    await waitFor(() => expect(rows()).toHaveLength(1));
    expect(Object.fromEntries(calls[0]!.searchParams)).toEqual({ page_size: "18" });
  });

  it("sends the user to log in when the session is refused", async () => {
    listServer(() => HttpResponse.json({ code: "UNAUTHENTICATED" }, { status: 401 }));
    renderScreen({ initialPage: { items: [ready(1)], next_cursor: "abc" } });
    fireEvent.click(screen.getByRole("button", { name: t.loadMore }));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith(`/login?next=${encodeURIComponent("/me")}`));
  });

  it("shows a failed next page with a retry", async () => {
    listServer(() => HttpResponse.json({ code: "INVALID_PAGE_TOKEN" }, { status: 400 }));
    renderScreen({ initialPage: { items: [ready(1)], next_cursor: "abc" } });
    fireEvent.click(screen.getByRole("button", { name: t.loadMore }));
    expect((await screen.findByRole("alert")).textContent).toContain(t.loadFailed);
    expect((screen.getByRole("button", { name: t.retry }) as HTMLButtonElement).disabled).toBe(false);
  });

  it("shows the progress and speed of an upload of this tab on its video", () => {
    const store = fakeStore([upload({ videoId: id(1) })]);
    renderScreen({ initialPage: { items: [video(1, "UPLOADING")], next_cursor: "" }, store });
    const [row] = rows();
    const bar = within(row!).getByRole("progressbar", { name: t.progress.label });
    expect(bar.getAttribute("aria-valuenow")).toBe("64");
    expect(within(row!).getByText("64% · 2,1 MB/s")).toBeTruthy();
  });

  it("puts an upload whose video is not listed yet first, and follows its progress", () => {
    const store = fakeStore([upload({ key: "upload-1", videoId: null, status: "preparing", progress: 0 })]);
    renderScreen({ initialPage: { items: [ready(1)], next_cursor: "" }, store });
    expect(rows()).toHaveLength(2);
    expect(within(rows()[0]!).getByText("Đang tải")).toBeTruthy();
    expect(within(rows()[0]!).getByText(t.progress.preparing)).toBeTruthy();

    act(() => store.set([upload({ key: "upload-1", videoId: id(9), status: "waiting", progress: 0.3 })]));
    expect(within(rows()[0]!).getByText(t.progress.waiting)).toBeTruthy();
    expect(within(rows()[0]!).getAllByText(t.status.UPLOADING)).toHaveLength(2);

    // Cancelled or failed uploads are not shown in their own row.
    act(() => store.set([upload({ key: "upload-1", videoId: id(9), status: "cancelled" })]));
    expect(rows()).toHaveLength(1);
  });
});

describe("MyVideosScreen refreshing", () => {
  let hidden = false;

  beforeEach(() => {
    hidden = false;
    vi.spyOn(document, "visibilityState", "get").mockImplementation(() => (hidden ? "hidden" : "visible"));
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "Date"] });
    vi.setSystemTime(renderedAt);
  });

  // Lets answers reach the screen: React Query hands results over on zero-delay timers.
  async function flush() {
    for (let round = 0; round < 10; round++) {
      await act(() => vi.advanceTimersByTimeAsync(1));
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  async function advance(ms: number) {
    await act(() => vi.advanceTimersByTimeAsync(ms));
    await flush();
  }

  it("asks again every 5 s while a video is unfinished, and stops once none is", async () => {
    const calls = listServer(
      () => HttpResponse.json(apiPage([video(1, "PROCESSING"), ready(2)])),
      () => HttpResponse.json(apiPage([ready(1), ready(2)])),
    );
    renderScreen({ initialPage: { items: [video(1, "PROCESSING"), ready(2)], next_cursor: "" } });

    await advance(4900);
    expect(calls).toHaveLength(0);
    await advance(100);
    expect(calls).toHaveLength(1);
    await advance(5000);
    expect(calls).toHaveLength(2);
    // The video turned READY while the list was asked again: its row links to it now.
    expect(within(rows()[0]!).getByRole("link", { name: "Video 1" }).getAttribute("href")).toBe(`/v/${id(1)}`);

    await advance(60_000);
    expect(calls).toHaveLength(2);
  });

  it("never asks again when every video is finished", async () => {
    const calls = listServer();
    renderScreen({ initialPage: { items: [ready(1), video(2, "FAILED")], next_cursor: "" } });
    await advance(60_000);
    expect(calls).toHaveLength(0);
  });

  it("does not ask while the tab is hidden", async () => {
    const uploading = video(1, "UPLOADING", { created_at: new Date(renderedAt).toISOString() });
    const calls = listServer(() => HttpResponse.json(apiPage([uploading])));
    renderScreen({ initialPage: { items: [uploading], next_cursor: "" } });
    hidden = true;
    await act(() => document.dispatchEvent(new Event("visibilitychange")));
    await advance(60_000);
    expect(calls).toHaveLength(0);

    hidden = false;
    await act(() => document.dispatchEvent(new Event("visibilitychange")));
    await advance(5000);
    expect(calls.length).toBeGreaterThan(0);
  });

  it("does not pile requests up behind a slow answer", async () => {
    let answered = 0;
    server.use(
      http.get("*/api/me/videos", async () => {
        // Slower than the interval.
        await new Promise((resolve) => setTimeout(resolve, 12_000));
        answered++;
        return HttpResponse.json(apiPage([video(1, "PROCESSING")]));
      }),
    );
    let started = 0;
    server.events.on("request:start", () => started++);
    renderScreen({ initialPage: { items: [video(1, "PROCESSING")], next_cursor: "" } });

    await advance(5000);
    expect(started).toBe(1);
    // Two more ticks pass while the first request runs: they wait for it instead of starting more.
    await advance(10_000);
    expect(started).toBe(1);
    await advance(2000);
    expect(answered).toBe(1);
    server.events.removeAllListeners();
  });

  it("asks again until an upload's new video is listed", async () => {
    const calls = listServer(
      () => HttpResponse.json(apiPage([ready(1)])),
      () => HttpResponse.json(apiPage([video(9, "PROCESSING"), ready(1)])),
      () => HttpResponse.json(apiPage([ready(9), ready(1)])),
    );
    const store = fakeStore([upload({ videoId: id(9), status: "processing", progress: 1 })]);
    renderScreen({ initialPage: { items: [ready(1)], next_cursor: "" }, store });
    // Shown first as processing until the list holds it.
    expect(within(rows()[0]!).getAllByText(t.status.PROCESSING)).toHaveLength(2);

    await advance(5000);
    await advance(5000);
    expect(calls).toHaveLength(2);
    expect(rows()).toHaveLength(2);
    await advance(5000);
    expect(calls).toHaveLength(3);
    expect(within(rows()[0]!).getAllByText(t.status.READY)).toHaveLength(2);
    await advance(60_000);
    expect(calls).toHaveLength(3);
  });

  // An UPLOADING video created `minutes` before the page was rendered.
  const uploadingSince = (n: number, minutes: number) =>
    video(n, "UPLOADING", { created_at: new Date(renderedAt - minutes * 60_000).toISOString() });

  it("asks for an UPLOADING video of another tab while its form lasts, then stops", async () => {
    const calls = listServer(() => HttpResponse.json(apiPage([uploadingSince(1, 14)])));
    renderScreen({ initialPage: { items: [uploadingSince(1, 14)], next_cursor: "" } });

    await advance(5000);
    expect(calls).toHaveLength(1);
    // The form of 15 minutes runs out 60 s after the page was rendered: the answer of that tick is the last.
    await advance(55_000);
    expect(calls).toHaveLength(12);
    await advance(60_000);
    expect(calls).toHaveLength(12);
  });

  it("never asks for an UPLOADING video whose form ran out long ago", async () => {
    const calls = listServer();
    renderScreen({ initialPage: { items: [uploadingSince(1, 3 * 24 * 60)], next_cursor: "" } });
    await advance(60_000);
    expect(calls).toHaveLength(0);
  });

  it("asks while a video is PROCESSING beside one given up, and stops once it is done", async () => {
    const calls = listServer(
      () => HttpResponse.json(apiPage([video(1, "PROCESSING"), uploadingSince(2, 60)])),
      () => HttpResponse.json(apiPage([ready(1), uploadingSince(2, 60)])),
    );
    renderScreen({ initialPage: { items: [video(1, "PROCESSING"), uploadingSince(2, 60)], next_cursor: "" } });

    await advance(5000);
    expect(calls).toHaveLength(1);
    await advance(5000);
    expect(calls).toHaveLength(2);
    await advance(60_000);
    expect(calls).toHaveLength(2);
  });

  it("keeps asking for the video this tab just completed while the list still says UPLOADING", async () => {
    // The form is older than its 15 minutes (a slow upload): only this tab's upload keeps the list asked.
    const calls = listServer(
      () => HttpResponse.json(apiPage([uploadingSince(9, 20)])),
      () => HttpResponse.json(apiPage([video(9, "PROCESSING")])),
      () => HttpResponse.json(apiPage([ready(9)])),
    );
    const store = fakeStore([upload({ videoId: id(9), status: "processing", progress: 1 })]);
    renderScreen({ initialPage: { items: [uploadingSince(9, 20)], next_cursor: "" }, store });

    await advance(5000);
    expect(calls).toHaveLength(1);
    await advance(5000);
    await advance(5000);
    expect(calls).toHaveLength(3);
    expect(within(rows()[0]!).getAllByText(t.status.READY)).toHaveLength(2);
    await advance(60_000);
    expect(calls).toHaveLength(3);
  });

  it("waits out the server's Retry-After before the first request", async () => {
    const calls = listServer(() => HttpResponse.json(apiPage([ready(1)])));
    renderScreen({ initialRetryAfterSeconds: 3 });
    await advance(2900);
    expect(calls).toHaveLength(0);
    await advance(200);
    expect(calls).toHaveLength(1);
  });
});
