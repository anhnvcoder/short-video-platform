import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { useRouter } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { afterAll, afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest";
import type { Locale } from "@/i18n/config";
import { messagesFor } from "@/i18n/messages";
import { formatCompact } from "@/lib/format";
import { server } from "@/lib/test/msw-server";
import type { FeedItem, FeedKind, FeedPage } from "./api";
import { FeedScreen } from "./feed-screen";

vi.mock("next/navigation", () => ({ useRouter: vi.fn() }));
// No MediaSource in jsdom: the pool takes the native path, which only sets video.src.
vi.mock("./hls-loader", () => ({ loadHls: () => Promise.resolve({ isSupported: () => false }) }));

const mediaOrigin = "http://127.0.0.1:9000";
// The server's clock for "2 days ago": 2026-10-22 10:00 in Vietnam, two days after the videos' published_at.
const renderedAt = Date.parse("2026-10-22T03:00:00Z");
const me = "0192f0c1-7a3e-7c4b-9d2e-000000000001";
const creator = "0192f0c1-7a3e-7c4b-9d2e-000000000002";

function item(n: number, overrides: Partial<FeedItem> = {}): FeedItem {
  return {
    video_id: `0192f0c1-0000-7000-8000-${String(n).padStart(12, "0")}`,
    author_id: creator,
    title: `Video ${n}`,
    duration_ms: 42_000,
    playlist_url: `${mediaOrigin}/media/hls/${n}/master.m3u8`,
    thumbnail_url: `${mediaOrigin}/media/thumbs/${n}.jpg`,
    published_at: "2026-10-20T08:00:00Z",
    stats: { view_count: 1_200_000, like_count: 12_400, liked_by_me: false },
    ...overrides,
  };
}

const page = (items: FeedItem[], next = ""): FeedPage => ({ items, next_cursor: next });

const problem = (status: number, code: string, headers: Record<string, string> = {}) =>
  HttpResponse.json(
    { type: "about:blank", title: "", status, detail: "", code },
    { status, headers: { "Content-Type": "application/problem+json", ...headers } },
  );

// Stands in for IntersectionObserver: a test says which item is on screen.
class FakeObserver {
  static current: FakeObserver | null = null;
  readonly elements = new Set<Element>();
  constructor(readonly callback: IntersectionObserverCallback) {
    FakeObserver.current = this;
  }
  observe(element: Element) {
    this.elements.add(element);
  }
  unobserve(element: Element) {
    this.elements.delete(element);
  }
  disconnect() {
    this.elements.clear();
  }
  show(index: number) {
    const target = [...this.elements].find((element) => (element as HTMLElement).dataset.index === String(index));
    if (!target) {
      throw new Error(`item ${index} is not observed`);
    }
    const entry = { target, isIntersecting: true, intersectionRatio: 1 } as unknown as IntersectionObserverEntry;
    act(() => this.callback([entry], this as unknown as IntersectionObserver));
  }
}

const router = { replace: vi.fn(), push: vi.fn() };

function renderFeed({
  kind = "explore",
  initialPage,
  initialPageFetchedAt,
  initialRetryAfterSeconds,
  locale = "vi",
  client = new QueryClient(),
}: {
  kind?: FeedKind;
  initialPage?: FeedPage;
  initialPageFetchedAt?: number;
  initialRetryAfterSeconds?: number;
  locale?: Locale;
  // The tab's client, shared by the renders of one test as it is by the pages of a tab.
  client?: QueryClient;
} = {}) {
  return render(
    <NextIntlClientProvider locale={locale} messages={{ feed: messagesFor(locale).feed }}>
      <QueryClientProvider client={client}>
        <FeedScreen
          kind={kind}
          initialPage={initialPage}
          initialPageFetchedAt={initialPageFetchedAt}
          initialRetryAfterSeconds={initialRetryAfterSeconds}
          mediaOrigin={mediaOrigin}
          currentUserId={me}
          renderedAt={renderedAt}
        />
      </QueryClientProvider>
    </NextIntlClientProvider>,
  );
}

// Runs fake time forward, letting requests and renders finish between timers.
async function advance(ms: number) {
  await act(() => vi.advanceTimersByTimeAsync(ms));
}

// Under fake timers, waits for an answer to reach the screen: its body is read with real I/O, and React Query hands the
// result over on a zero-delay timer. (Testing Library's waitFor cannot be used here: it ends on a timer of its own.)
// Fake time runs 10 ms per attempt, so a check that needs retries Retry-After apart asks for more attempts.
async function settle(check: () => void, attempts = 100) {
  for (let attempt = 1; ; attempt++) {
    await advance(10);
    try {
      check();
      return;
    } catch (error) {
      if (attempt === attempts) {
        throw error;
      }
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
}

const t = (locale: Locale = "vi") => messagesFor(locale).feed;

// A like button with stats: one name in both states, the action then the count the button shows (WCAG 2.5.3);
// aria-pressed alone tells whether the video is liked.
const likeName = (locale: Locale = "vi") => new RegExp(`^${t(locale).likeWithCount.replace("{count}", ".+")}$`);

function articles() {
  return within(screen.getByRole("feed")).getAllByRole("article");
}

function videoIn(article: Element | undefined) {
  return article?.querySelector("video") ?? null;
}

// What axe's aria-prohibited-attr and label-content-name-mismatch rules look for (the unit run has no axe): a label only
// on an element with a role (a plain div or span may not carry one), and a labelled button's name holding the words the
// button shows, in order (WCAG 2.5.3).
function ariaProblems(): string[] {
  const problems: string[] = [];
  for (const element of document.body.querySelectorAll("div[aria-label]:not([role]), span[aria-label]:not([role])")) {
    problems.push(`aria-label without a role: ${element.outerHTML.slice(0, 80)}`);
  }
  const words = (text: string) =>
    text
      .toLowerCase()
      .split(/[^\p{L}\p{N}]+/u)
      .filter(Boolean);
  for (const button of document.body.querySelectorAll("button[aria-label]")) {
    const shown = words(button.textContent ?? "");
    const name = words(button.getAttribute("aria-label") ?? "");
    const holds = shown.length === 0 || name.some((_, at) => shown.every((word, i) => name[at + i] === word));
    if (!holds) {
      problems.push(`name "${button.getAttribute("aria-label")}" does not hold the text "${button.textContent}"`);
    }
  }
  return problems;
}

// jsdom has no scrollIntoView: records the calls instead, until the test ends.
function recordScrolls() {
  const scrolled: { element: Element; options: unknown }[] = [];
  Object.defineProperty(Element.prototype, "scrollIntoView", {
    configurable: true,
    value(this: Element, options: unknown) {
      scrolled.push({ element: this, options });
    },
  });
  onTestFinished(() => {
    Reflect.deleteProperty(Element.prototype, "scrollIntoView");
  });
  return scrolled;
}

// Mocks are restored before each test rather than after it: Testing Library unmounts after this file's afterEach, and
// the unmount releases the players through the stubbed media methods.
beforeEach(() => {
  vi.restoreAllMocks();
  vi.mocked(useRouter).mockReturnValue(router as unknown as ReturnType<typeof useRouter>);
  vi.stubGlobal("IntersectionObserver", FakeObserver);
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
  window.history.replaceState(null, "", "/");
});

afterAll(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

afterEach(() => {
  vi.useRealTimers();
  router.replace.mockReset();
  router.push.mockReset();
  FakeObserver.current = null;
});

describe("FeedScreen", () => {
  it.each<Locale>(["vi", "en"])("%s: renders the server's first page with tabs and actions", (locale) => {
    renderFeed({ locale, initialPage: page([item(1), item(2)]) });
    const messages = t(locale);
    const tabs = screen.getByRole("tablist", { name: messages.tabs.label });
    expect(within(tabs).getByRole("tab", { name: messages.tabs.explore }).getAttribute("aria-selected")).toBe("true");
    expect(articles().map((article) => article.getAttribute("aria-label"))).toEqual(["Video 1", "Video 2", null]);
    const first = articles()[0] as HTMLElement;
    const like = within(first).getByRole("button", {
      name: messages.likeWithCount.replace("{count}", formatCompact(12_400, locale)),
    });
    expect(like.textContent).toBe(formatCompact(12_400, locale));
    expect(within(first).getByRole("img", { name: /1,2 triệu|1.2 million/ })).toBeTruthy();
    expect(within(first).getByRole("button", { name: messages.follow })).toBeTruthy();
    expect(within(first).getByRole("button", { name: messages.shareLabel }).textContent).toBe(messages.share);
    expect(first.querySelector("img")?.getAttribute("src")).toBe(`${mediaOrigin}/media/thumbs/1.jpg`);
  });

  it.each<[Locale, string]>([
    ["vi", "@minhanh · 1 ngày trước"],
    ["en", "@minhanh · 1 day ago"],
  ])("%s: shows the author's name, linked to their profile, with the handle and the video's age", (locale, line) => {
    const author = { user_id: creator, handle: "minhanh", display_name: "Minh Anh" };
    renderFeed({ locale, initialPage: page([item(1, { author, published_at: "2026-10-21T02:00:00Z" })]) });
    const first = articles()[0] as HTMLElement;
    const link = within(first).getByRole("link", { name: "Minh Anh" });
    expect(link.getAttribute("href")).toBe("/u/minhanh");
    expect(within(first).getByText(line)).toBeTruthy();
    // The avatar shows the name's first letter.
    expect(within(first).getByRole("button", { name: t(locale).follow }).textContent).toContain("M");
  });

  it("renders a name holding HTML as text, isolated from the handle after it", () => {
    const author = { user_id: creator, handle: "minhanh", display_name: '<img src=x onerror="alert(1)">' };
    renderFeed({ initialPage: page([item(1, { author })]) });
    const first = articles()[0] as HTMLElement;
    const link = within(first).getByRole("link", { name: author.display_name });
    expect(link.querySelector("bdi")?.textContent).toBe(author.display_name);
    expect(first.querySelector("img[src='x']")).toBeNull();
  });

  it("without the author keeps the line, empty, so the title does not move when it comes", () => {
    renderFeed({
      initialPage: page([item(1), item(2, { author: { user_id: creator, handle: "abc", display_name: "A" } })]),
    });
    const [without, withAuthor] = articles() as [HTMLElement, HTMLElement];
    expect(within(without).queryByRole("link")).toBeNull();
    expect(within(without).queryByText(/@/)).toBeNull();
    const line = (article: HTMLElement) =>
      within(article)
        .getByText(/^Video/)
        .closest("button")?.previousElementSibling;
    expect(line(without)?.className).toBe(line(withAuthor)?.className);
    expect(line(without)?.className).toContain("min-h-6");
  });

  it("share copies this origin's link to the video and says so", async () => {
    const writeText = vi.fn(() => Promise.resolve());
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    onTestFinished(() => {
      Reflect.deleteProperty(navigator, "clipboard");
    });
    renderFeed({ initialPage: page([item(1)]) });
    fireEvent.click(within(articles()[0] as HTMLElement).getByRole("button", { name: t().shareLabel }));
    await waitFor(() => expect(screen.getByText(t().toast.linkCopied)).toBeTruthy());
    expect(writeText).toHaveBeenCalledWith(`${window.location.origin}/v/${item(1).video_id}`);
  });

  it.each([
    [
      "the browser refuses the clipboard",
      { writeText: () => Promise.reject(new DOMException("denied", "NotAllowedError")) },
    ],
    ["there is no Clipboard API", undefined],
  ])("share says the link was not copied when %s", async (_, clipboard) => {
    Object.defineProperty(navigator, "clipboard", { value: clipboard, configurable: true });
    onTestFinished(() => {
      Reflect.deleteProperty(navigator, "clipboard");
    });
    renderFeed({ initialPage: page([item(1)]) });
    fireEvent.click(within(articles()[0] as HTMLElement).getByRole("button", { name: t().shareLabel }));
    await waitFor(() => expect(screen.getByText(t().toast.copyFailed)).toBeTruthy());
    expect(screen.queryByText(t().toast.linkCopied)).toBeNull();
  });

  it("without stats hides both counts, and like still works", async () => {
    const liked = vi.fn();
    server.use(
      http.put("*/api/videos/:id/like", ({ params }) => {
        liked(params.id);
        return new HttpResponse(null, { status: 204 });
      }),
    );
    renderFeed({ initialPage: page([item(1, { stats: undefined })]) });
    const first = articles()[0] as HTMLElement;
    const like = within(first).getByRole("button", { name: t().like });
    expect(like.textContent).toBe(t().likeText);
    expect(within(first).queryByRole("img", { name: /lượt xem/ })).toBeNull();
    expect(like.getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(like);
    // The name keeps the "Thích" the button shows; aria-pressed tells the state.
    expect(within(first).getByRole("button", { name: t().like }).getAttribute("aria-pressed")).toBe("true");
    await waitFor(() => expect(liked).toHaveBeenCalledWith(item(1).video_id));
  });

  it.each<Locale>(["vi", "en"])(
    "%s: loading, playing, a play error and an empty feed break no ARIA rule axe checks",
    async (locale) => {
      // First page loading: the skeleton.
      server.use(http.get("*/api/feed/following", () => new Promise<never>(() => {})));
      const loading = renderFeed({ locale, kind: "following" });
      expect(screen.getByRole("status", { name: t(locale).loading }).getAttribute("aria-busy")).toBe("true");
      expect(ariaProblems()).toEqual([]);
      loading.unmount();

      // A video loading, then playing, then failing; one item with stats, one without, liked.
      server.use(http.put("*/api/videos/:id/like", () => new HttpResponse(null, { status: 204 })));
      const feed = renderFeed({ locale, initialPage: page([item(1), item(2, { stats: undefined })]) });
      const first = articles()[0] as HTMLElement;
      expect(within(first).getByRole("status", { name: t(locale).loading })).toBeTruthy();
      fireEvent.click(within(articles()[1] as HTMLElement).getByRole("button", { name: t(locale).like }));
      expect(ariaProblems()).toEqual([]);
      const video = await waitFor(() => {
        const element = videoIn(first);
        expect(element).toBeTruthy();
        return element as HTMLVideoElement;
      });
      fireEvent(video, new Event("playing"));
      await waitFor(() => expect(within(first).queryByRole("status", { name: t(locale).loading })).toBeNull());
      expect(ariaProblems()).toEqual([]);
      fireEvent(video, new Event("error"));
      await waitFor(() => expect(within(first).getByRole("alert")).toBeTruthy());
      expect(ariaProblems()).toEqual([]);
      feed.unmount();

      renderFeed({ locale, initialPage: page([]) });
      expect(screen.getByText(t(locale).empty.exploreTitle)).toBeTruthy();
      expect(ariaProblems()).toEqual([]);
    },
  );

  it("renders titles as text only", () => {
    const title = '<img src=x onerror="alert(1)"><b>bold</b>';
    renderFeed({ initialPage: page([item(1, { title })]) });
    expect(screen.getByText(title)).toBeTruthy();
    expect(document.querySelector('img[src="x"]')).toBeNull();
    expect(document.querySelector("b")).toBeNull();
  });

  it("drops a thumbnail outside the media origin", () => {
    renderFeed({ initialPage: page([item(1, { thumbnail_url: "https://tracker.example/pixel.gif" })]) });
    expect(document.querySelector('img[src*="tracker"]')).toBeNull();
  });

  it("has no follow button on the user's own videos", () => {
    renderFeed({ initialPage: page([item(1, { author_id: me })]) });
    const first = articles()[0] as HTMLElement;
    expect(within(first).queryByRole("button", { name: t().follow })).toBeNull();
    expect(within(first).getByRole("img", { name: t().author })).toBeTruthy();
  });

  it("explore: follows an author after the server confirms, on every video of that author", async () => {
    let answer: () => void = () => {};
    const followed = vi.fn();
    server.use(
      http.put("*/api/me/following/:id", async ({ params }) => {
        followed(params.id);
        await new Promise<void>((resolve) => (answer = resolve));
        return new HttpResponse(null, { status: 204 });
      }),
    );
    renderFeed({ initialPage: page([item(1), item(2)]) });
    const [first, second] = articles() as [HTMLElement, HTMLElement];
    fireEvent.click(within(first).getByRole("button", { name: t().follow }));
    await waitFor(() => expect(followed).toHaveBeenCalledWith(creator));
    // Not optimistic: the state changes once the server has answered.
    expect(within(first).getByRole("button", { name: t().follow })).toHaveProperty("disabled", true);
    await act(async () => answer());
    await waitFor(() => expect(within(first).getByRole("button", { name: t().unfollow })).toBeTruthy());
    expect(within(second).getByRole("button", { name: t().unfollow })).toBeTruthy();
  });

  it("following: authors start followed and a tap unfollows", async () => {
    const unfollowed = vi.fn();
    server.use(
      http.delete("*/api/me/following/:id", ({ params }) => {
        unfollowed(params.id);
        return new HttpResponse(null, { status: 204 });
      }),
    );
    renderFeed({ kind: "following", initialPage: page([item(1)]) });
    const first = articles()[0] as HTMLElement;
    fireEvent.click(within(first).getByRole("button", { name: t().unfollow }));
    await waitFor(() => expect(within(first).getByRole("button", { name: t().follow })).toBeTruthy());
    expect(unfollowed).toHaveBeenCalledWith(creator);
  });

  it("a failed like puts the button back and shows a toast (engagement-service down)", async () => {
    server.use(http.put("*/api/videos/:id/like", () => problem(503, "UNAVAILABLE")));
    renderFeed({ initialPage: page([item(1)]) });
    const first = articles()[0] as HTMLElement;
    fireEvent.click(within(first).getByRole("button", { name: likeName(), pressed: false }));
    expect(within(first).getByRole("button", { name: likeName(), pressed: true }).textContent).toBe(
      formatCompact(12_400, "vi"),
    );
    await waitFor(() => expect(screen.getByText(t().toast.likeFailed)).toBeTruthy());
    const like = within(first).getByRole("button", { name: likeName(), pressed: false });
    expect(like.getAttribute("aria-pressed")).toBe("false");
    expect(like.textContent).toBe(formatCompact(12_400, "vi"));
    expect(screen.getByRole("button", { name: t().toast.retry })).toBeTruthy();
  });

  it("following without anyone followed suggests Explore", () => {
    renderFeed({ kind: "following", initialPage: page([]) });
    expect(screen.getByRole("heading", { name: t().empty.followingTitle })).toBeTruthy();
    expect(screen.getByRole("link", { name: t().empty.followingAction }).getAttribute("href")).toBe("/");
    expect(screen.queryByRole("feed")).toBeNull();
  });

  it("an empty explore feed says there is nothing yet", () => {
    renderFeed({ kind: "explore", initialPage: page([]) });
    expect(screen.getByRole("heading", { name: t().empty.exploreTitle })).toBeTruthy();
  });

  it("shows the end after the last page", () => {
    renderFeed({ initialPage: page([item(1)]) });
    const end = articles().at(-1) as HTMLElement;
    expect(within(end).getByRole("heading", { name: t().end.title })).toBeTruthy();
    expect(within(end).getByRole("button", { name: t().end.action })).toBeTruthy();
  });

  it("loads the next page by cursor near the end", async () => {
    const cursors: (string | null)[] = [];
    server.use(
      http.get("*/api/feed/explore", ({ request }) => {
        cursors.push(new URL(request.url).searchParams.get("cursor"));
        return HttpResponse.json(page([item(3)]));
      }),
    );
    renderFeed({ initialPage: page([item(1), item(2)], "c1") });
    await waitFor(() => expect(articles().map((a) => a.getAttribute("aria-label"))).toContain("Video 3"));
    expect(cursors).toEqual(["c1"]);
    expect(within(articles().at(-1) as HTMLElement).getByRole("heading", { name: t().end.title })).toBeTruthy();
  });

  it("after a later page, the end becomes current: the last video stops, and ↓ and Next reach it", async () => {
    const scrolled: Element[] = [];
    Object.defineProperty(Element.prototype, "scrollIntoView", {
      configurable: true,
      value(this: Element) {
        scrolled.push(this);
      },
    });
    try {
      server.use(http.get("*/api/feed/explore", () => HttpResponse.json(page([item(3)]))));
      renderFeed({ initialPage: page([item(1), item(2)], "c1") });
      await waitFor(() => expect(articles()).toHaveLength(4));
      FakeObserver.current?.show(2);
      const last = await waitFor(() => {
        const element = (articles()[2] as HTMLElement).querySelector("video");
        expect(element).toBeTruthy();
        return element as HTMLVideoElement;
      });
      Object.defineProperty(last, "paused", { configurable: true, get: () => false });
      const end = articles()[3] as HTMLElement;
      expect(within(end).getByRole("heading", { name: t().end.title })).toBeTruthy();

      fireEvent.keyDown(document.body, { key: "ArrowDown" });
      fireEvent.click(screen.getByRole("button", { name: t().next }));
      expect(scrolled).toEqual([end, end]);

      vi.mocked(HTMLMediaElement.prototype.pause).mockClear();
      FakeObserver.current?.show(3);
      expect(vi.mocked(HTMLMediaElement.prototype.pause).mock.contexts).toContain(last);
      expect(screen.getByRole("button", { name: t().next })).toHaveProperty("disabled", true);
    } finally {
      Reflect.deleteProperty(Element.prototype, "scrollIntoView");
    }
  });

  it("a page that arrives while the loading item is current: the first new video takes over, the old item is gone", async () => {
    const scrolled = recordScrolls();
    const cursors: (string | null)[] = [];
    let answer: () => void = () => {};
    server.use(
      http.get("*/api/feed/explore", async ({ request }) => {
        cursors.push(new URL(request.url).searchParams.get("cursor"));
        await new Promise<void>((resolve) => (answer = resolve));
        return HttpResponse.json(page([item(3), item(4), item(5)], "c2"));
      }),
    );
    renderFeed({ initialPage: page([item(1), item(2)], "c1") });
    await waitFor(() => expect(cursors).toEqual(["c1"]));
    // The user reaches the item after the last video while the next page still loads.
    const loadingItem = articles()[2] as HTMLElement;
    expect(within(loadingItem).getByLabelText(t().loading)).toBeTruthy();
    FakeObserver.current?.show(2);

    await act(async () => answer());
    await waitFor(() => expect(articles()).toHaveLength(6));
    const [, , third, fourth, , last] = articles() as HTMLElement[];
    expect(third?.getAttribute("aria-label")).toBe("Video 3");
    // A browser holding the old element on screen would find it gone; the observer watches the new last item only.
    expect(loadingItem.isConnected).toBe(false);
    const observed = [...(FakeObserver.current?.elements ?? [])];
    expect(observed).not.toContain(loadingItem);
    expect(observed).toContain(last);
    expect(scrolled).toEqual([{ element: third, options: { block: "start", behavior: "instant" } }]);
    // Video 3 is the current item: it plays, and once it can, the pool loads its neighbours.
    await waitFor(() => expect(videoIn(third)?.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/3/master.m3u8`));
    expect(vi.mocked(HTMLMediaElement.prototype.play).mock.contexts).toContain(videoIn(third));
    fireEvent(videoIn(third) as HTMLVideoElement, new Event("canplay"));
    await waitFor(() => expect(videoIn(fourth)).toBeTruthy());
    // Not on one of the last two videos of the new list: no next page yet.
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(cursors).toEqual(["c1"]);
  });

  it("the item after the last video never asks for the next page itself", async () => {
    const cursors: (string | null)[] = [];
    server.use(
      http.get("*/api/feed/explore", ({ request }) => {
        cursors.push(new URL(request.url).searchParams.get("cursor"));
        return HttpResponse.json(page([item(3)], "c2"));
      }),
    );
    renderFeed({ initialPage: page([item(1), item(2)], "c1") });
    await waitFor(() => expect(articles()).toHaveLength(4));
    FakeObserver.current?.show(3);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(cursors).toEqual(["c1"]);
    FakeObserver.current?.show(2);
    await waitFor(() => expect(cursors).toEqual(["c1", "c2"]));
  });

  it("a page that arrives while the user is on a video does not move the feed", async () => {
    const scrolled = recordScrolls();
    server.use(http.get("*/api/feed/explore", () => HttpResponse.json(page([item(3)]))));
    renderFeed({ initialPage: page([item(1), item(2)], "c1") });
    await waitFor(() => expect(articles()).toHaveLength(4));
    expect(scrolled).toEqual([]);
    expect(videoIn(articles()[0])?.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/1/master.m3u8`);
  });

  it("a new visit shows the server's new first page, not the feed kept from the last visit", async () => {
    const client = new QueryClient();
    const explore = renderFeed({ client, initialPage: page([item(1)]) });
    expect(within(articles()[0] as HTMLElement).getByRole("button", { name: likeName(), pressed: false })).toBeTruthy();
    explore.unmount();
    renderFeed({ client, kind: "following", initialPage: page([item(5)]) }).unmount();
    // The feed leaves the cache with its screen, as it does between two navigations.
    await waitFor(() => expect(client.getQueryCache().find({ queryKey: ["feed", "explore"] })).toBeUndefined());

    const liked = { view_count: 3, like_count: 12_401, liked_by_me: true };
    renderFeed({ client, initialPage: page([item(1, { stats: liked }), item(2)]) });
    expect(articles().map((article) => article.getAttribute("aria-label"))).toEqual(["Video 1", "Video 2", null]);
    const like = within(articles()[0] as HTMLElement).getByRole("button", { name: likeName(), pressed: true });
    expect(like.getAttribute("aria-pressed")).toBe("true");
    expect(like.textContent).toBe(formatCompact(12_401, "vi"));
  });

  it("Back right after a like: the replayed first page is fetched again, and the video shows liked", async () => {
    const calls: (string | null)[] = [];
    const liked = { view_count: 3, like_count: 12_401, liked_by_me: true };
    server.use(
      http.put("*/api/videos/:id/like", () => new HttpResponse(null, { status: 204 })),
      http.get("*/api/feed/explore", ({ request }) => {
        calls.push(new URL(request.url).searchParams.get("cursor"));
        return HttpResponse.json(page([item(9), item(1, { stats: liked })]));
      }),
    );
    const client = new QueryClient();
    // The server's stamp is two minutes off the browser's clock: only its identity counts.
    const first = { initialPage: page([item(1), item(2)]), initialPageFetchedAt: Date.now() - 120_000 };
    const explore = renderFeed({ client, ...first });
    const like = within(articles()[0] as HTMLElement).getByRole("button", { name: likeName(), pressed: false });
    fireEvent.click(like);
    expect(like.getAttribute("aria-pressed")).toBe("true");
    await new Promise((resolve) => setTimeout(resolve, 50));
    explore.unmount();
    renderFeed({ client, kind: "following", initialPage: page([item(5)]), initialPageFetchedAt: Date.now() }).unmount();
    await waitFor(() => expect(client.getQueryCache().find({ queryKey: ["feed", "explore"] })).toBeUndefined());
    // A new server render is shown as it came.
    expect(calls).toEqual([]);

    // Back: the router hands over the payload of the first visit, at once, with the like missing from it.
    renderFeed({ client, ...first });
    expect(within(articles()[0] as HTMLElement).getByRole("button", { name: likeName(), pressed: false })).toBeTruthy();
    await waitFor(() =>
      expect(articles().map((article) => article.getAttribute("aria-label"))).toEqual(["Video 9", "Video 1", null]),
    );
    expect(calls).toEqual([null]);
    const unlike = within(articles()[1] as HTMLElement).getByRole("button", { name: likeName(), pressed: true });
    expect(unlike.getAttribute("aria-pressed")).toBe("true");
    expect(unlike.textContent).toBe(formatCompact(12_401, "vi"));
    // Video 1 moved to index 1: the players follow the items to their new places.
    await waitFor(() =>
      expect(videoIn(articles()[0])?.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/9/master.m3u8`),
    );
    fireEvent(videoIn(articles()[0]) as HTMLVideoElement, new Event("canplay"));
    await waitFor(() =>
      expect(videoIn(articles()[1])?.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/1/master.m3u8`),
    );
  });

  it("a first page from a new server render is not fetched again, even with the server's clock two minutes off", async () => {
    const calls = vi.fn();
    server.use(
      http.get("*/api/feed/explore", () => {
        calls();
        return HttpResponse.json(page([item(1)]));
      }),
    );
    renderFeed({ initialPage: page([item(1)]), initialPageFetchedAt: Date.now() - 120_000 }).unmount();
    renderFeed({ initialPage: page([item(1)]), initialPageFetchedAt: Date.now() + 120_000 });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(calls).not.toHaveBeenCalled();
  });

  it("fetches the first page itself when the server gave none, showing a skeleton meanwhile", async () => {
    server.use(http.get("*/api/feed/following", () => HttpResponse.json(page([item(1)]))));
    renderFeed({ kind: "following" });
    expect(screen.getByLabelText(t().loading).getAttribute("aria-busy")).toBe("true");
    await waitFor(() => expect(articles()[0]?.getAttribute("aria-label")).toBe("Video 1"));
  });

  it("401 sends the user to log in and come back to this page", async () => {
    window.history.replaceState(null, "", "/following?from=nav");
    server.use(http.get("*/api/feed/following", () => problem(401, "UNAUTHENTICATED")));
    renderFeed({ kind: "following" });
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login?next=%2Ffollowing%3Ffrom%3Dnav"));
  });

  it("401 on a like sends the user to log in", async () => {
    server.use(http.put("*/api/videos/:id/like", () => problem(401, "UNAUTHENTICATED")));
    renderFeed({ initialPage: page([item(1)]) });
    fireEvent.click(within(articles()[0] as HTMLElement).getByRole("button", { name: likeName(), pressed: false }));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login?next=%2F"));
  });

  it("401 on a follow sends the user to log in", async () => {
    window.history.replaceState(null, "", "/?tab=1");
    server.use(http.put("*/api/me/following/:id", () => problem(401, "UNAUTHENTICATED")));
    renderFeed({ initialPage: page([item(1)]) });
    fireEvent.click(within(articles()[0] as HTMLElement).getByRole("button", { name: t().follow }));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login?next=%2F%3Ftab%3D1"));
    expect(screen.queryByText(t().toast.followFailed)).toBeNull();
  });

  it("401 on a view sends the user to log in", async () => {
    window.history.replaceState(null, "", "/following");
    server.use(http.post("*/api/videos/:id/views", () => problem(401, "UNAUTHENTICATED")));
    renderFeed({ kind: "following", initialPage: page([item(1)]) });
    const video = await waitFor(() => {
      const element = (articles()[0] as HTMLElement).querySelector("video");
      expect(element).toBeTruthy();
      return element as HTMLVideoElement;
    });
    let time = 0;
    Object.defineProperty(video, "paused", { configurable: true, get: () => false });
    Object.defineProperty(video, "currentTime", { configurable: true, get: () => time });
    for (; time <= 3; time += 0.25) {
      fireEvent(video, new Event("timeupdate"));
    }
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login?next=%2Ffollowing"));
  });

  it("401 on a later page sends the user to log in", async () => {
    server.use(http.get("*/api/feed/explore", () => problem(401, "UNAUTHENTICATED")));
    renderFeed({ initialPage: page([item(1)], "c1") });
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login?next=%2F"));
  });

  it("a rate-limited like locks every like and follow until Retry-After, then offers the retry", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const calls: string[] = [];
    server.use(
      http.put("*/api/videos/:id/like", () => {
        calls.push("PUT");
        return calls.length === 1
          ? problem(429, "RATE_LIMITED", { "Retry-After": "4" })
          : new HttpResponse(null, { status: 204 });
      }),
    );
    renderFeed({ initialPage: page([item(1), item(2)]) });
    const [first, second] = articles() as [HTMLElement, HTMLElement];
    fireEvent.click(within(first).getByRole("button", { name: likeName(), pressed: false }));
    await settle(() => expect(screen.getByText(t().toast.rateLimited)).toBeTruthy());

    const buttons = () => [
      within(first).getByRole("button", { name: likeName(), pressed: false }),
      within(second).getByRole("button", { name: likeName(), pressed: false }),
      within(first).getByRole("button", { name: t().follow }),
    ];
    expect(buttons().map((button) => button.hasAttribute("disabled"))).toEqual([true, true, true]);
    expect(screen.queryByRole("button", { name: t().toast.retry })).toBeNull();
    await advance(3800);
    expect(buttons().map((button) => button.hasAttribute("disabled"))).toEqual([true, true, true]);
    expect(screen.queryByRole("button", { name: t().toast.retry })).toBeNull();
    expect(calls).toEqual(["PUT"]);

    await advance(300);
    expect(buttons().map((button) => button.hasAttribute("disabled"))).toEqual([false, false, false]);
    fireEvent.click(screen.getByRole("button", { name: t().toast.retry }));
    await settle(() => expect(calls).toEqual(["PUT", "PUT"]));
    expect(within(first).getByRole("button", { name: likeName(), pressed: true }).getAttribute("aria-pressed")).toBe(
      "true",
    );
  });

  it("429 waits for Retry-After, then tries again", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    let calls = 0;
    server.use(
      http.get("*/api/feed/explore", () => {
        calls += 1;
        return calls === 1 ? problem(429, "RATE_LIMITED", { "Retry-After": "3" }) : HttpResponse.json(page([item(1)]));
      }),
    );
    renderFeed({ kind: "explore" });
    await advance(100);
    expect(calls).toBe(1);
    await advance(2800);
    expect(calls).toBe(1);
    expect(screen.queryByRole("feed")).toBeNull();
    await advance(200);
    expect(calls).toBe(2);
    await settle(() => expect(articles()[0]?.getAttribute("aria-label")).toBe("Video 1"));
  });

  it("the first page's retry button waits for the Retry-After of the last 429", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    let calls = 0;
    server.use(
      http.get("*/api/feed/explore", () => {
        calls += 1;
        return calls <= 4 ? problem(429, "RATE_LIMITED", { "Retry-After": "5" }) : HttpResponse.json(page([item(1)]));
      }),
    );
    renderFeed({ kind: "explore" });
    // The first request and three retries, 5 s apart.
    const retry = () => screen.getByRole("button", { name: t().loadError.retry });
    await settle(() => expect(screen.getByText(t().loadError.rateLimited)).toBeTruthy(), 2000);
    expect(calls).toBe(4);
    expect(retry()).toHaveProperty("disabled", true);
    await advance(4800);
    expect(retry()).toHaveProperty("disabled", true);
    fireEvent.click(retry());
    expect(calls).toBe(4);

    await advance(300);
    expect(retry()).toHaveProperty("disabled", false);
    fireEvent.click(retry());
    await settle(() => expect(articles()[0]?.getAttribute("aria-label")).toBe("Video 1"));
    expect(calls).toBe(5);
  });

  it("a later page's retry waits for the Retry-After of the last 429 and cannot be sent twice", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    let calls = 0;
    let answer: () => void = () => {};
    server.use(
      http.get("*/api/feed/explore", async () => {
        calls += 1;
        if (calls <= 4) {
          return problem(429, "RATE_LIMITED", { "Retry-After": "2" });
        }
        await new Promise<void>((resolve) => (answer = resolve));
        return HttpResponse.json(page([item(2)]));
      }),
    );
    renderFeed({ initialPage: page([item(1)], "c1") });
    const tail = () => articles().at(-1) as HTMLElement;
    const retry = () => within(tail()).getByRole("button", { name: t().loadError.retry });
    // The first request and three retries, 2 s apart.
    await settle(() => expect(within(tail()).getByText(t().loadError.rateLimited)).toBeTruthy(), 1000);
    expect(calls).toBe(4);
    expect(retry()).toHaveProperty("disabled", true);
    await advance(1800);
    expect(retry()).toHaveProperty("disabled", true);

    await advance(300);
    fireEvent.click(retry());
    await settle(() => expect(calls).toBe(5));
    // Loading while the retry runs: no button to send it again.
    expect(within(tail()).queryByRole("button", { name: t().loadError.retry })).toBeNull();
    expect(within(tail()).getByLabelText(t().loading)).toBeTruthy();
    await act(async () => answer());
    await settle(() => expect(articles().map((article) => article.getAttribute("aria-label"))).toContain("Video 2"));
    expect(calls).toBe(5);
  });

  it("waits for the Retry-After the server got before asking for the first page itself", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    let calls = 0;
    server.use(
      http.get("*/api/feed/explore", () => {
        calls += 1;
        return HttpResponse.json(page([item(1)]));
      }),
    );
    renderFeed({ kind: "explore", initialRetryAfterSeconds: 5 });
    expect(screen.getByLabelText(t().loading).getAttribute("aria-busy")).toBe("true");
    await advance(4900);
    expect(calls).toBe(0);
    await advance(200);
    expect(calls).toBe(1);
    await settle(() => expect(articles()[0]?.getAttribute("aria-label")).toBe("Video 1"));
  });

  it("counts a view once after 2 s of playback of the current item", async () => {
    const views = vi.fn();
    server.use(
      http.post("*/api/videos/:id/views", ({ params }) => {
        views(params.id);
        return new HttpResponse(null, { status: 202 });
      }),
    );
    renderFeed({ initialPage: page([item(1), item(2)]) });
    const video = await waitFor(() => {
      const element = (articles()[0] as HTMLElement).querySelector("video");
      expect(element).toBeTruthy();
      return element as HTMLVideoElement;
    });
    let time = 0;
    Object.defineProperty(video, "paused", { configurable: true, get: () => false });
    Object.defineProperty(video, "currentTime", { configurable: true, get: () => time });
    for (; time <= 3; time += 0.25) {
      fireEvent(video, new Event("timeupdate"));
    }
    await waitFor(() => expect(views).toHaveBeenCalledTimes(1));
    expect(views).toHaveBeenCalledWith(item(1).video_id);
    for (; time <= 10; time += 0.25) {
      fireEvent(video, new Event("timeupdate"));
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(views).toHaveBeenCalledTimes(1);
  });

  it("moves the players with the current item and marks the playing video", async () => {
    renderFeed({ initialPage: page([item(1), item(2), item(3), item(4)]) });
    // The neighbour loads only once the current video plays.
    const first = await waitFor(() => videoIn(articles()[0]) as HTMLVideoElement);
    expect(document.querySelectorAll("video")).toHaveLength(1);
    fireEvent(first, new Event("playing"));
    await waitFor(() => expect(document.querySelectorAll("video")).toHaveLength(2));
    // Video 3 was not a neighbour: it loads now, and video 4 waits for it.
    FakeObserver.current?.show(2);
    const [, second, third, fourth] = articles() as HTMLElement[];
    const playing = await waitFor(() => videoIn(third) as HTMLVideoElement);
    expect(playing.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/3/master.m3u8`);
    expect(videoIn(second)).toBeTruthy();
    expect(videoIn(fourth)).toBeNull();
    fireEvent(playing, new Event("playing"));
    expect(playing.dataset.state).toBe("playing");
    expect(within(third as HTMLElement).queryByLabelText(t().loading)).toBeNull();
    await waitFor(() => expect(document.querySelectorAll("video")).toHaveLength(3));
    expect(videoIn(fourth)?.getAttribute("src")).toBe(`${mediaOrigin}/media/hls/4/master.m3u8`);
  });

  it("loads the current poster first, lazy-loads its neighbours' and renders no other", async () => {
    // Videos no other test renders: React keeps one preload per URL for the whole file.
    renderFeed({ initialPage: page([item(41), item(42), item(43), item(44)]) });
    const preload = (n: number) =>
      document.head
        .querySelector(`link[rel="preload"][as="image"][href="${mediaOrigin}/media/thumbs/${n}.jpg"]`)
        ?.getAttribute("fetchpriority") ?? null;
    expect(preload(41)).toBe("high");
    expect([preload(42), preload(43), preload(44)]).toEqual([null, null, null]);
    const poster = (index: number) => articles()[index]?.querySelector("img") ?? null;
    const first = poster(0);
    expect(first?.getAttribute("fetchpriority")).toBe("high");
    expect(first?.hasAttribute("loading")).toBe(false);
    expect(first?.hasAttribute("decoding")).toBe(false);
    expect(poster(1)?.getAttribute("src")).toBe(`${mediaOrigin}/media/thumbs/42.jpg`);
    expect(poster(1)?.getAttribute("loading")).toBe("lazy");
    expect(poster(1)?.getAttribute("decoding")).toBe("async");
    expect(poster(1)?.hasAttribute("fetchpriority")).toBe(false);
    expect(poster(2)).toBeNull();
    expect(poster(3)).toBeNull();

    // The window moves with the current item.
    FakeObserver.current?.show(2);
    expect(poster(0)).toBeNull();
    expect(poster(1)?.getAttribute("loading")).toBe("lazy");
    expect(poster(2)?.getAttribute("fetchpriority")).toBe("high");
    expect(poster(3)?.getAttribute("src")).toBe(`${mediaOrigin}/media/thumbs/44.jpg`);
    // The preload is for the first paint only.
    expect(preload(43)).toBeNull();
  });

  it("puts no preload in the head for a first poster outside the media origin", () => {
    renderFeed({ initialPage: page([item(1, { thumbnail_url: "https://tracker.example/1.jpg" }), item(2)]) });
    expect(document.head.querySelector('link[href^="https://tracker.example"]')).toBeNull();
  });

  it("the first tap turns the sound on, the next one pauses", async () => {
    renderFeed({ initialPage: page([item(1)]) });
    const first = articles()[0] as HTMLElement;
    const video = await waitFor(() => first.querySelector("video") as HTMLVideoElement);
    expect(video.muted).toBe(true);
    fireEvent.click(within(first).getByRole("button", { name: t().pause }));
    expect(video.muted).toBe(false);
    expect(within(first).getByRole("button", { name: t().mute })).toBeTruthy();
    fireEvent.click(within(first).getByRole("button", { name: t().pause }));
    expect(within(first).getByRole("button", { name: t().play })).toBeTruthy();
  });

  it("keys: M mutes, Space pauses, but not while typing in a field", async () => {
    renderFeed({ initialPage: page([item(1)]) });
    const first = articles()[0] as HTMLElement;
    const video = await waitFor(() => first.querySelector("video") as HTMLVideoElement);
    fireEvent.keyDown(window, { key: "m" });
    expect(video.muted).toBe(false);
    fireEvent.keyDown(document.body, { key: " " });
    expect(within(first).getByRole("button", { name: t().play })).toBeTruthy();

    const field = document.body.appendChild(document.createElement("input"));
    fireEvent.keyDown(field, { key: "m" });
    fireEvent.keyDown(field, { key: " " });
    expect(video.muted).toBe(false);
    expect(within(first).getByRole("button", { name: t().play })).toBeTruthy();
  });

  it("shows the offline banner while the browser is offline", () => {
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    renderFeed({ initialPage: page([item(1)]) });
    expect(screen.getByText(t().offline.title)).toBeTruthy();
  });

  it("switching tabs navigates between the two feeds", () => {
    renderFeed({ initialPage: page([item(1)]) });
    fireEvent.click(screen.getByRole("tab", { name: t().tabs.following }));
    expect(router.push).toHaveBeenCalledWith("/following");
  });
});
