import { act, renderHook, waitFor } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { ApiError, type VideoStats } from "./api";
import { useLike } from "./use-like";

const videoId = "0192f0c1-0000-7000-8000-000000000001";
const likeUrl = `*/api/videos/${videoId}/like`;

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

function renderLike(stats: VideoStats | undefined, onError = vi.fn()) {
  const view = renderHook(() => useLike(videoId, stats, onError));
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

  it("follows newer stats until the first tap, then the taps decide", async () => {
    const api = likeServer();
    const onError = vi.fn();
    const { result, rerender } = renderHook(({ stats }) => useLike(videoId, stats, onError), {
      initialProps: { stats: { view_count: 5, like_count: 10, liked_by_me: false } as VideoStats },
    });
    expect(result.current).toMatchObject({ liked: false, count: 10 });
    // The feed fetched the page again: the server now says liked.
    rerender({ stats: { view_count: 6, like_count: 11, liked_by_me: true } });
    expect(result.current).toMatchObject({ liked: true, count: 11 });

    act(() => result.current.toggle());
    expect(result.current).toMatchObject({ liked: false, count: 10 });
    await api.release();
    expect(api.calls).toEqual(["DELETE"]);
    // Stats read before the unlike reached the server do not undo it.
    rerender({ stats: { view_count: 7, like_count: 11, liked_by_me: true } });
    expect(result.current).toMatchObject({ liked: false, count: 10 });
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
