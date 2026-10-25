import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { useLinkStatus } from "next/link";
import { useRouter } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { afterAll, afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest";
import type { Locale } from "@/i18n/config";
import { linkPendingMessages } from "@/components/shell/link-pending-messages";
import { messagesFor } from "@/i18n/messages";
import { formatCompact } from "@/lib/format";
import { server } from "@/lib/test/msw-server";
import type { FeedItem } from "./api";
import { ShareScreen } from "./share-screen";

vi.mock("next/navigation", () => ({ useRouter: vi.fn() }));
// Whether the navigation a link started still waits for its page; only the App Router knows, so a test says.
vi.mock("next/link", async (importOriginal) => ({
  ...(await importOriginal<typeof import("next/link")>()),
  useLinkStatus: vi.fn(() => ({ pending: false })),
}));
// No MediaSource in jsdom: the pool takes the native path, which only sets video.src.
vi.mock("./hls-loader", () => ({ loadHls: () => Promise.resolve({ isSupported: () => false }) }));

const mediaOrigin = "http://127.0.0.1:9000";
const viewer = "0192f0c1-7a3e-7c4b-9d2e-000000000001";
const creator = "0192f0c1-7a3e-7c4b-9d2e-000000000002";
const videoId = "0192f0c1-0000-7000-8000-000000000001";
// Two days after the video was published.
const loadedAt = Date.parse("2026-10-22T08:00:00Z");
const page = `/v/${videoId}`;
const next = encodeURIComponent(page);

const baseVideo: FeedItem = {
  video_id: videoId,
  author_id: creator,
  title: "Chiều Hà Nội cuối thu",
  duration_ms: 42_000,
  playlist_url: `${mediaOrigin}/media/hls/1/master.m3u8`,
  thumbnail_url: `${mediaOrigin}/media/thumbs/1.jpg`,
  published_at: "2026-10-20T08:00:00Z",
  author: { user_id: creator, handle: "minhanh", display_name: "Minh Anh" },
  stats: { view_count: 1_200_000, like_count: 12_400, liked_by_me: false },
};

const router = { replace: vi.fn(), push: vi.fn() };

function renderShare({
  video = baseVideo,
  viewerId = null,
  locale = "vi",
}: { video?: FeedItem; viewerId?: string | null; locale?: Locale } = {}) {
  const messages = messagesFor(locale);
  return render(
    // The messages the /v/[id] page gives its provider: no other namespace reaches the screen.
    <NextIntlClientProvider
      locale={locale}
      messages={{ feed: messages.feed, share: messages.share, ...linkPendingMessages(messages) }}
    >
      <QueryClientProvider client={new QueryClient()}>
        <ShareScreen video={video} viewerId={viewerId} mediaOrigin={mediaOrigin} loadedAt={loadedAt} appName="SVP" />
      </QueryClientProvider>
    </NextIntlClientProvider>,
  );
}

const feed = (locale: Locale = "vi") => messagesFor(locale).feed;
const share = (locale: Locale = "vi") => messagesFor(locale).share;

// The rail over the video (small screens); the side panel holds the same actions for wide screens.
function stage() {
  return screen.getByRole("article");
}

function likeButton() {
  return within(stage()).getByRole("button", {
    name: feed().likeWithCount.replace("{count}", formatCompact(12_400, "vi")),
  });
}

async function playingVideo(): Promise<HTMLVideoElement> {
  return waitFor(() => {
    const element = stage().querySelector("video");
    expect(element).toBeTruthy();
    return element as HTMLVideoElement;
  });
}

// Plays the video for `seconds` of playback through timeupdate events, as the browser reports it.
function play(video: HTMLVideoElement, seconds: number) {
  let time = 0;
  Object.defineProperty(video, "paused", { configurable: true, get: () => false });
  Object.defineProperty(video, "currentTime", { configurable: true, get: () => time });
  for (; time <= seconds; time += 0.25) {
    fireEvent(video, new Event("timeupdate"));
  }
}

function recordViews() {
  const views = vi.fn();
  server.use(
    http.post("*/api/videos/:id/views", ({ params }) => {
      views(params.id);
      return new HttpResponse(null, { status: 202 });
    }),
  );
  return views;
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.mocked(useRouter).mockReturnValue(router as unknown as ReturnType<typeof useRouter>);
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
  window.history.replaceState(null, "", page);
});

afterEach(() => {
  router.replace.mockReset();
});

afterAll(() => {
  vi.restoreAllMocks();
});

describe("ShareScreen for a guest", () => {
  it.each<Locale>(["vi", "en"])("%s: shows the video, its author and counts, and ways in", (locale) => {
    renderShare({ locale });
    const header = screen.getByRole("banner");
    expect(
      within(header)
        .getByRole("link", { name: share(locale).logIn })
        .getAttribute("href"),
    ).toBe(`/login?next=${next}`);
    expect(
      within(header)
        .getByRole("link", { name: share(locale).register })
        .getAttribute("href"),
    ).toBe(`/register?next=${next}`);
    for (const open of screen.getAllByRole("link", { name: share(locale).openInApp })) {
      expect(open.getAttribute("href")).toBe("/");
    }
    expect(
      screen.getAllByText(share(locale).guestHint.replace("{name}", "Minh Anh")).length +
        screen.getAllByText(share(locale).moreBody.replace("{name}", "Minh Anh")).length,
    ).toBe(2);

    const video = stage();
    expect(video.getAttribute("aria-label")).toBe(baseVideo.title);
    // A guest cannot open profiles: the name is text, not a link.
    expect(screen.queryByRole("link", { name: "Minh Anh" })).toBeNull();
    const ago = locale === "vi" ? "2 ngày trước" : "2 days ago";
    expect(within(video).getByText(`@minhanh · ${ago}`)).toBeTruthy();
    expect(within(video).getByRole("img", { name: /1,2 triệu|1.2 million/ })).toBeTruthy();
    expect(video.querySelector("img")?.getAttribute("src")).toBe(baseVideo.thumbnail_url);
    // The wide-screen panel.
    expect(screen.getByRole("heading", { level: 1, name: baseVideo.title })).toBeTruthy();
    expect(
      screen.getByText(
        [
          feed(locale).likeCount.replace("{count}", formatCompact(12_400, locale)),
          feed(locale).viewCount.replace("{count}", formatCompact(1_200_000, locale)),
          ago,
        ]
          .join(" · ")
          // Testing Library reads the no-break space Intl puts in "12,4 N" as a plain one.
          .replace(/\s/g, " "),
      ),
    ).toBeTruthy();
  });

  it("asks to log in on like, coming back here, and Escape closes it with focus back on the button", async () => {
    renderShare();
    const like = likeButton();
    like.focus();
    fireEvent.click(like);
    const dialog = screen.getByRole("dialog", { name: share().prompt.likeTitle });
    const login = within(dialog).getByRole("link", { name: share().prompt.logIn });
    expect(login.getAttribute("href")).toBe(`/login?next=${next}`);
    expect(within(dialog).getByRole("link", { name: share().prompt.register }).getAttribute("href")).toBe(
      `/register?next=${next}`,
    );
    expect(document.activeElement).toBe(login);
    // Nothing was liked: no request (an unhandled one fails the test) and the button is not pressed.
    expect(like.getAttribute("aria-pressed")).toBe("false");

    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(document.activeElement).toBe(like);
  });

  it("asks to log in on follow; Later closes it", () => {
    renderShare();
    fireEvent.click(within(stage()).getByRole("button", { name: feed().follow }));
    const dialog = screen.getByRole("dialog", { name: share().prompt.followTitle });
    fireEvent.click(within(dialog).getByRole("button", { name: share().prompt.later }));
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("the wide-screen like and follow ask to log in too", () => {
    renderShare();
    fireEvent.click(screen.getByRole("button", { name: share().like, pressed: false }));
    expect(screen.getByRole("dialog", { name: share().prompt.likeTitle })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: share().prompt.close }));
    fireEvent.click(screen.getByRole("button", { name: share().follow }));
    expect(screen.getByRole("dialog", { name: share().prompt.followTitle })).toBeTruthy();
  });

  it("records no view however long the guest watches", async () => {
    const views = recordViews();
    renderShare();
    play(await playingVideo(), 5);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(views).not.toHaveBeenCalled();
  });

  it("copies this page's link", async () => {
    const writeText = vi.fn(() => Promise.resolve());
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    onTestFinished(() => {
      Reflect.deleteProperty(navigator, "clipboard");
    });
    renderShare();
    fireEvent.click(screen.getByRole("button", { name: share().copyLink }));
    await waitFor(() => expect(screen.getByText(feed().toast.linkCopied)).toBeTruthy());
    expect(writeText).toHaveBeenCalledWith(`${window.location.origin}${page}`);
  });

  it("renders a title and a name holding HTML as text only", () => {
    const title = `"><img src=x onerror="window.__xss=1"><script>window.__xss=1</script>`;
    const name = `<b onmouseover="x">Minh</b>`;
    const { container } = renderShare({
      video: { ...baseVideo, title, author: { ...baseVideo.author!, display_name: name } },
    });
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe(title);
    expect(stage().getAttribute("aria-label")).toBe(title);
    expect(container.querySelector("img[src='x'], script, b")).toBeNull();
    expect(screen.getAllByText(name).length).toBeGreaterThan(0);
  });

  it("keeps room for two lines of the guest hint, so the bar under the video does not change height with the font", () => {
    const { unmount } = renderShare();
    const hint = (text: string) => screen.getByText(text).className.split(" ");
    expect(hint(share().guestHint.replace("{name}", "Minh Anh"))).toEqual(
      expect.arrayContaining(["min-h-10", "text-sm"]),
    );
    unmount();
    const bare: FeedItem = { ...baseVideo };
    delete bare.author;
    renderShare({ video: bare });
    expect(hint(share().guestHintNoName)).toEqual(expect.arrayContaining(["min-h-10", "text-sm"]));
  });

  it("without author or stats hides them and still plays", async () => {
    const bare: FeedItem = { ...baseVideo };
    delete bare.author;
    delete bare.stats;
    renderShare({ video: bare });
    expect(within(stage()).queryByText(/@/)).toBeNull();
    expect(within(stage()).queryByRole("img", { name: /lượt xem/ })).toBeNull();
    expect(within(stage()).getByRole("button", { name: feed().like }).textContent).toBe(feed().likeText);
    expect(screen.getByText(share().guestHintNoName)).toBeTruthy();
    expect((await playingVideo()).getAttribute("src")).toBe(baseVideo.playlist_url);
  });

  it.each<Locale>(["vi", "en"])(
    "%s: the app's name, a link to the feed, shows a spinner after it while the feed's page loads",
    async (locale) => {
      onTestFinished(() => {
        vi.mocked(useLinkStatus).mockReturnValue({ pending: false });
      });
      vi.mocked(useLinkStatus).mockReturnValue({ pending: true });
      renderShare({ locale });
      const home = within(screen.getByRole("banner")).getAllByRole("link")[0]!;
      expect(home.getAttribute("href")).toBe("/");
      await waitFor(() =>
        expect(within(home).getByRole("status").textContent).toBe(messagesFor(locale).common.loading),
      );
    },
  );

  it("loads the poster first: a high-priority preload in the head and an eager image", () => {
    renderShare();
    const link = document.head.querySelector(`link[rel="preload"][as="image"][href="${baseVideo.thumbnail_url}"]`);
    expect(link?.getAttribute("fetchpriority")).toBe("high");
    const poster = stage().querySelector("img");
    expect(poster?.getAttribute("fetchpriority")).toBe("high");
    expect(poster?.hasAttribute("loading")).toBe(false);
  });

  it("shows no poster and a playback error for media off the media origin", async () => {
    renderShare({
      video: { ...baseVideo, thumbnail_url: "https://evil.example/t.jpg", playlist_url: "https://evil.example/m.m3u8" },
    });
    expect(stage().querySelector("img")).toBeNull();
    expect(document.head.querySelector('link[href^="https://evil.example"]')).toBeNull();
    await waitFor(() => expect(within(stage()).getByRole("alert").textContent).toContain(feed().playError.title));
    expect(stage().querySelector("video")?.getAttribute("src")).toBeNull();
  });
});

describe("ShareScreen for a logged-in user", () => {
  it("has no login links, and the author's name opens their profile", () => {
    renderShare({ viewerId: viewer });
    expect(screen.queryByRole("link", { name: share().logIn })).toBeNull();
    expect(screen.queryByText(share().guestHint.replace("{name}", "Minh Anh"))).toBeNull();
    for (const link of screen.getAllByRole("link", { name: "Minh Anh" })) {
      expect(link.getAttribute("href")).toBe("/u/minhanh");
    }
  });

  it("likes for real, with one name and aria-pressed telling the state", async () => {
    const likes: string[] = [];
    server.use(
      http.put("*/api/videos/:id/like", ({ params }) => {
        likes.push(String(params.id));
        return new HttpResponse(null, { status: 204 });
      }),
    );
    renderShare({ viewerId: viewer });
    const like = likeButton();
    fireEvent.click(like);
    expect(like.getAttribute("aria-pressed")).toBe("true");
    expect(like.getAttribute("aria-label")).toBe(feed().likeWithCount.replace("{count}", formatCompact(12_401, "vi")));
    await waitFor(() => expect(likes).toEqual([videoId]));
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("follows for real", async () => {
    const follows: string[] = [];
    server.use(
      http.put("*/api/me/following/:id", ({ params }) => {
        follows.push(String(params.id));
        return new HttpResponse(null, { status: 204 });
      }),
    );
    renderShare({ viewerId: viewer });
    fireEvent.click(within(stage()).getByRole("button", { name: feed().follow }));
    await waitFor(() => expect(within(stage()).getByRole("button", { name: feed().unfollow })).toBeTruthy());
    expect(follows).toEqual([creator]);
    expect(screen.getByRole("button", { name: share().following })).toBeTruthy();
  });

  it("has no follow button on the user's own video", () => {
    renderShare({ viewerId: creator });
    expect(within(stage()).queryByRole("button", { name: feed().follow })).toBeNull();
    expect(screen.queryByRole("button", { name: share().follow })).toBeNull();
  });

  it("records one view after 2 s of playback", async () => {
    const views = recordViews();
    renderShare({ viewerId: viewer });
    play(await playingVideo(), 4);
    await waitFor(() => expect(views).toHaveBeenCalledTimes(1));
    expect(views).toHaveBeenCalledWith(videoId);
  });

  it("a refused session on like sends the user to log in and come back here", async () => {
    server.use(
      http.put("*/api/videos/:id/like", () =>
        HttpResponse.json(
          { code: "UNAUTHENTICATED" },
          { status: 401, headers: { "Content-Type": "application/problem+json" } },
        ),
      ),
    );
    renderShare({ viewerId: viewer });
    fireEvent.click(likeButton());
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith(`/login?next=${next}`));
  });

  it("a rate-limited like says so", async () => {
    server.use(
      http.put("*/api/videos/:id/like", () =>
        HttpResponse.json(
          { code: "RATE_LIMITED" },
          { status: 429, headers: { "Content-Type": "application/problem+json", "Retry-After": "3" } },
        ),
      ),
    );
    renderShare({ viewerId: viewer });
    fireEvent.click(likeButton());
    await waitFor(() => expect(screen.getByText(feed().toast.rateLimited)).toBeTruthy());
    expect(likeButton().hasAttribute("disabled")).toBe(true);
  });
});
