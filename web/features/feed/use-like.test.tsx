import { QueryClient, QueryClientProvider, type InfiniteData } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { ApiError, type FeedItem, type FeedPage, type VideoStats } from "./api";
import { useFeed } from "./use-feed";
import { useLike } from "./use-like";

const videoId = "0192f0c1-0000-7000-8000-000000000001";
const otherId = "0192f0c1-0000-7000-8000-000000000002";
const likeUrl = `*/api/videos/${videoId}/like`;

function feedItem(id: string, stats?: VideoStats): FeedItem {
  return {
    video_id: id,
    author_id: "0192f0c1-7a3e-7c4b-9d2e-000000000002",
    title: "",
    duration_ms: 1000,
    playlist_url: "",
    thumbnail_url: "",
    published_at: "2026-10-20T08:00:00Z",
    ...(stats ? { stats } : {}),
  };
}

// Records each like call; each answer waits for `release()` so a test can tap while requests are in flight. The calls
// get the statuses in order, the last one from then on.
function likeServer(...statuses: number[]) {
  const calls: string[] = [];
  const waiting: (() => void)[] = [];
  const handler = async ({ request }: { request: Request }) => {
    calls.push(request.method);
    const status = (statuses.length > 1 ? statuses.shift() : statuses[0]) ?? 204;
    await new Promise<void>((resolve) => waiting.push(resolve));
    return status === 204
      ? new HttpResponse(null, { status })
      : HttpResponse.json({ code: "UNAVAILABLE" }, { status, headers: { "Content-Type": "application/problem+json" } });
  };
  server.use(http.put(likeUrl, handler), http.delete(likeUrl, handler));
  return {
    calls,
    async release() {
      await waitFor(() => expect(waiting.length).toBeGreaterThan(0));
      await act(async () => waiting.shift()?.());
    },
  };
}

// The query client stands for the browser tab: the renders of one test that share it share the tab's taps.
function inTab(client: QueryClient) {
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  );
  return wrapper;
}

function renderLike(stats: VideoStats | undefined, onError = vi.fn(), client = new QueryClient()) {
  const view = renderHook(() => useLike(videoId, stats, onError), { wrapper: inTab(client) });
  return { ...view, onError };
}

describe("useLike", () => {
  it("changes the button and the count at once, before the server answers", async () => {
    const api = likeServer();
    const { result } = renderLike({ view_count: 5, like_count: 10, liked_by_me: false });
    act(() => result.current.toggle());
    expect(result.current).toMatchObject({ liked: true, count: 11 });
    await api.release();
    expect(api.calls).toEqual(["PUT"]);
    expect(result.current).toMatchObject({ liked: true, count: 11 });
  });

  it("unlikes a video the caller likes", async () => {
    const api = likeServer();
    const { result } = renderLike({ view_count: 5, like_count: 10, liked_by_me: true });
    act(() => result.current.toggle());
    expect(result.current).toMatchObject({ liked: false, count: 9 });
    await api.release();
    expect(api.calls).toEqual(["DELETE"]);
  });

  it("puts the state back and reports the error when the server refuses (503)", async () => {
    const api = likeServer(503);
    const { result, onError } = renderLike({ view_count: 5, like_count: 10, liked_by_me: false });
    act(() => result.current.toggle());
    expect(result.current.liked).toBe(true);
    await api.release();
    await waitFor(() => expect(result.current).toMatchObject({ liked: false, count: 10 }));
    expect(onError).toHaveBeenCalledTimes(1);
    const [error, wanted, retry] = onError.mock.calls[0] ?? [];
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).status).toBe(503);
    expect(wanted).toBe(true);
    expect(typeof retry).toBe("function");
  });

  it("retry asks for the failed like again", async () => {
    const api = likeServer(503, 204);
    const { result, onError } = renderLike({ view_count: 5, like_count: 10, liked_by_me: false });
    act(() => result.current.toggle());
    await api.release();
    await waitFor(() => expect(onError).toHaveBeenCalledTimes(1));
    const [, wanted, retry] = onError.mock.calls[0] as [unknown, boolean, () => void];
    expect(wanted).toBe(true);
    act(() => retry());
    expect(result.current).toMatchObject({ liked: true, count: 11 });
    await api.release();
    expect(api.calls).toEqual(["PUT", "PUT"]);
    expect(result.current).toMatchObject({ liked: true, count: 11 });
  });

  it("retry asks for the last tap's state: like then unlike while the PUT fails, and retry unlikes", async () => {
    const api = likeServer(503, 204);
    const { result, onError } = renderLike({ view_count: 5, like_count: 10, liked_by_me: false });
    act(() => {
      result.current.toggle();
      result.current.toggle();
    });
    await api.release();
    await waitFor(() => expect(onError).toHaveBeenCalledTimes(1));
    const [, wanted, retry] = onError.mock.calls[0] as [unknown, boolean, () => void];
    expect(wanted).toBe(false);
    expect(result.current.liked).toBe(false);
    // The PUT may have reached the server before failing, so the retry sends the unlike rather than nothing.
    act(() => retry());
    await api.release();
    expect(api.calls).toEqual(["PUT", "DELETE"]);
    expect(result.current).toMatchObject({ liked: false, count: 10 });
  });

  it("ends on the state of the last tap when taps come faster than the server", async () => {
    const api = likeServer();
    const { result } = renderLike({ view_count: 5, like_count: 10, liked_by_me: false });
    act(() => {
      result.current.toggle();
      result.current.toggle();
      result.current.toggle();
      result.current.toggle();
    });
    expect(result.current.liked).toBe(false);
    // One request at a time: the PUT of the first tap, then a DELETE to reach the last tap's state.
    await api.release();
    await api.release();
    await waitFor(() => expect(api.calls).toEqual(["PUT", "DELETE"]));
    expect(result.current).toMatchObject({ liked: false, count: 10 });
  });

  it("an odd number of quick taps ends liked with a single request", async () => {
    const api = likeServer();
    const { result } = renderLike({ view_count: 5, like_count: 10, liked_by_me: false });
    act(() => {
      result.current.toggle();
      result.current.toggle();
      result.current.toggle();
    });
    await api.release();
    await waitFor(() => expect(result.current.liked).toBe(true));
    expect(api.calls).toEqual(["PUT"]);
  });

  it("follows newer stats until the first tap; stats read before its request ended do not undo it", async () => {
    const api = likeServer();
    const onError = vi.fn();
    const { result, rerender } = renderHook(({ stats }) => useLike(videoId, stats, onError), {
      initialProps: { stats: { view_count: 5, like_count: 10, liked_by_me: false } as VideoStats },
      wrapper: inTab(new QueryClient()),
    });
    expect(result.current).toMatchObject({ liked: false, count: 10 });
    // The feed fetched the page again: the server now says liked.
    rerender({ stats: { view_count: 6, like_count: 11, liked_by_me: true } });
    expect(result.current).toMatchObject({ liked: true, count: 11 });

    act(() => result.current.toggle());
    expect(result.current).toMatchObject({ liked: false, count: 10 });
    // Stats read before the unlike reached the server do not undo it, neither while it runs nor once it is answered.
    rerender({ stats: { view_count: 7, like_count: 11, liked_by_me: true } });
    expect(result.current).toMatchObject({ liked: false, count: 10 });
    await api.release();
    expect(api.calls).toEqual(["DELETE"]);
    expect(result.current).toMatchObject({ liked: false, count: 10 });
    // Stats read after it come from the server's state since: another tab liked the video again.
    rerender({ stats: { view_count: 8, like_count: 11, liked_by_me: true } });
    expect(result.current).toMatchObject({ liked: true, count: 11 });
  });

  it("a tap still pending shows on a screen mounted later in the tab, whatever its stats, and stays once answered", async () => {
    const api = likeServer();
    const client = new QueryClient();
    const unliked = { view_count: 5, like_count: 10, liked_by_me: false };
    const first = renderLike(unliked, vi.fn(), client);
    act(() => first.result.current.toggle());
    first.unmount();

    // Back: the router hands the new screen a page read before the like, while the PUT is still on its way.
    const again = renderLike(unliked, vi.fn(), client);
    expect(again.result.current).toMatchObject({ liked: true, count: 11 });
    await api.release();
    expect(again.result.current).toMatchObject({ liked: true, count: 11 });
    expect(api.calls).toEqual(["PUT"]);

    // Another tab has a client of its own.
    expect(renderLike(unliked).result.current).toMatchObject({ liked: false, count: 10 });
  });

  it("a request still running when its screen leaves: a tap on the screen mounted again waits for it, then is sent", async () => {
    const api = likeServer();
    const client = new QueryClient();
    const unliked = { view_count: 5, like_count: 10, liked_by_me: false };
    const first = renderLike(unliked, vi.fn(), client);
    act(() => first.result.current.toggle());
    first.unmount();

    const again = renderLike(unliked, vi.fn(), client);
    act(() => again.result.current.toggle());
    expect(again.result.current).toMatchObject({ liked: false, count: 10 });
    // One request at a time across screens: the unlike waits for the PUT of the screen that left.
    await waitFor(() => expect(api.calls).toEqual(["PUT"]));
    await api.release();
    await api.release();
    expect(api.calls).toEqual(["PUT", "DELETE"]);
    expect(again.result.current).toMatchObject({ liked: false, count: 10 });
  });

  it("a failure after its screen left is told to the screen of the last tap, and the button goes back", async () => {
    const api = likeServer(503);
    const client = new QueryClient();
    const unliked = { view_count: 5, like_count: 10, liked_by_me: false };
    const first = renderLike(unliked, vi.fn(), client);
    act(() => first.result.current.toggle());
    first.unmount();
    const again = renderLike(unliked, vi.fn(), client);
    act(() => {
      again.result.current.toggle();
      again.result.current.toggle();
    });
    await api.release();
    await waitFor(() => expect(again.onError).toHaveBeenCalledTimes(1));
    expect(again.onError.mock.calls[0]?.[1]).toBe(true);
    expect(first.onError).not.toHaveBeenCalled();
    expect(again.result.current).toMatchObject({ liked: false, count: 10 });
    expect(api.calls).toEqual(["PUT"]);
  });

  it("a like applied but its answer lost: the button goes back, stats read afterwards show the like, a tap unlikes", async () => {
    const api = likeServer(503, 204);
    const client = new QueryClient();
    const first = renderLike({ view_count: 5, like_count: 10, liked_by_me: false }, vi.fn(), client);
    act(() => first.result.current.toggle());
    await api.release();
    await waitFor(() => expect(first.onError).toHaveBeenCalledTimes(1));
    expect(first.result.current).toMatchObject({ liked: false, count: 10 });
    first.unmount();

    // A screen whose page was read once the request had failed: the PUT had reached the server after all.
    const fresh = renderLike({ view_count: 6, like_count: 11, liked_by_me: true }, vi.fn(), client);
    expect(fresh.result.current).toMatchObject({ liked: true, count: 11 });
    act(() => fresh.result.current.toggle());
    expect(fresh.result.current).toMatchObject({ liked: false, count: 10 });
    await api.release();
    expect(api.calls).toEqual(["PUT", "DELETE"]);
    expect(fresh.result.current).toMatchObject({ liked: false, count: 10 });
  });

  it("an unlike from another tab after the like ended: stats read after it show it, and a tap likes again", async () => {
    const api = likeServer();
    const client = new QueryClient();
    const first = renderLike({ view_count: 5, like_count: 10, liked_by_me: false }, vi.fn(), client);
    act(() => first.result.current.toggle());
    await api.release();
    first.unmount();

    const fresh = renderLike({ view_count: 6, like_count: 10, liked_by_me: false }, vi.fn(), client);
    expect(fresh.result.current).toMatchObject({ liked: false, count: 10 });
    act(() => fresh.result.current.toggle());
    expect(fresh.result.current).toMatchObject({ liked: true, count: 11 });
    await api.release();
    expect(api.calls).toEqual(["PUT", "PUT"]);
  });

  it("stores the server's answer into every cached feed that holds the video, and only there", async () => {
    const api = likeServer();
    const client = new QueryClient();
    const stats = { view_count: 5, like_count: 10, liked_by_me: false };
    const other = { ...feedItem(otherId), stats };
    const feed = (items: FeedItem[]): InfiniteData<FeedPage> => ({
      pages: [{ items, next_cursor: "" }],
      pageParams: [""],
    });
    client.setQueryData(["feed", "explore"], feed([feedItem(videoId, stats), other]));
    client.setQueryData(["feed", "following"], feed([feedItem(videoId, stats)]));
    const { result } = renderLike(stats, vi.fn(), client);
    act(() => result.current.toggle());
    await api.release();
    const liked = { view_count: 5, like_count: 11, liked_by_me: true };
    await waitFor(() =>
      expect(client.getQueryData(["feed", "explore"])).toEqual(feed([feedItem(videoId, liked), other])),
    );
    expect(client.getQueryData(["feed", "following"])).toEqual(feed([feedItem(videoId, liked)]));
  });

  describe("while the feed's next page loads", () => {
    const stats = { view_count: 5, like_count: 10, liked_by_me: false };
    const first: FeedPage = { items: [feedItem(videoId, stats)], next_cursor: "c1" };

    // A screen of the explore feed: the like of its first video, with the stats the feed holds, as FeedScreen reads
    // them. The next page waits for `deliver`.
    function renderFeedLike(client: QueryClient) {
      const reads: ((page: FeedPage) => void)[] = [];
      server.use(
        http.get("*/api/feed/explore", async () =>
          HttpResponse.json(await new Promise<FeedPage>((resolve) => reads.push(resolve))),
        ),
      );
      const view = renderHook(
        () => {
          const feed = useFeed("explore", first, undefined, true);
          return { feed, like: useLike(videoId, feed.data?.pages[0]?.items[0]?.stats, vi.fn()) };
        },
        { wrapper: inTab(client) },
      );
      return {
        ...view,
        async loadNext() {
          act(() => void view.result.current.feed.fetchNextPage());
          await waitFor(() => expect(reads).toHaveLength(1));
        },
        async deliver(page: FeedPage) {
          await act(async () => reads[0]?.(page));
          await waitFor(() => expect(client.isFetching()).toBe(0));
        },
      };
    }

    it("a like and an unlike that both end before the page lands: the unlike stays", async () => {
      const api = likeServer();
      const client = new QueryClient();
      const { result, loadNext, deliver } = renderFeedLike(client);
      await loadNext();
      act(() => result.current.like.toggle());
      await api.release();
      await waitFor(() => expect(client.isMutating()).toBe(0));
      act(() => result.current.like.toggle());
      await api.release();
      await waitFor(() => expect(client.isMutating()).toBe(0));

      await deliver({ items: [feedItem(otherId, stats)], next_cursor: "" });
      expect(result.current.feed.data?.pages).toHaveLength(2);
      expect(result.current.like).toMatchObject({ liked: false, count: 10 });
      expect(result.current.feed.data?.pages[0]?.items[0]?.stats).toEqual(stats);
      expect(api.calls).toEqual(["PUT", "DELETE"]);
    });

    it("the state goes back only into the feed whose page landed: another feed read since keeps what it read", async () => {
      const api = likeServer();
      const client = new QueryClient();
      const { result, loadNext, deliver } = renderFeedLike(client);
      await loadNext();
      act(() => result.current.like.toggle());
      await api.release();
      await waitFor(() => expect(client.isMutating()).toBe(0));
      // Following read after another tab unliked the video.
      const following: InfiniteData<FeedPage> = {
        pages: [{ items: [feedItem(videoId, stats)], next_cursor: "" }],
        pageParams: [""],
      };
      client.setQueryData(["feed", "following"], following);

      await deliver({ items: [feedItem(otherId, stats)], next_cursor: "" });
      expect(result.current.like).toMatchObject({ liked: true, count: 11 });
      expect(client.getQueryData(["feed", "following"])).toEqual(following);
    });
  });

  it("without stats hides the count but still likes", async () => {
    const api = likeServer();
    const { result } = renderLike(undefined);
    expect(result.current).toMatchObject({ liked: false, count: null });
    act(() => result.current.toggle());
    expect(result.current).toMatchObject({ liked: true, count: null });
    await api.release();
    expect(api.calls).toEqual(["PUT"]);
  });
});
