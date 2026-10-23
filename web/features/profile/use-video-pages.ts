import { useInfiniteQuery } from "@tanstack/react-query";
import { useState } from "react";
import { retryDelay, shouldRetry } from "@/features/feed/api";
import { fetchMyVideos, fetchUserVideos, type ProfileVideoPage } from "./api";

// While a video of the list may still change by itself (needsRefresh), "My videos" asks for the list again this often,
// so the status changes and the thumbnail appears without a reload.
export const refreshIntervalMs = 5000;

// How long the upload form of a new video can be used (uploadFormTTL of video-service). After it nobody can send the
// file any more: an UPLOADING video only waits for the clean-up job, which turns it FAILED within about an hour.
export const uploadFormLifetimeMs = 15 * 60 * 1000;

// Whether the list may still change by itself, so it is worth asking again:
//   - a PROCESSING video turns READY or FAILED within minutes;
//   - an UPLOADING video this tab is uploading (awaitedIds) turns PROCESSING once the file is up. The tab keeps its id
//     from the form until processing ends, so a list asked just after completing, which may still say UPLOADING, is
//     asked again;
//   - any other UPLOADING video (another tab or device) can still be sent while its form lasts, counted from
//     created_at. After that it was given up (cancelled, tab closed, form replaced) and asking every 5 s until the
//     clean-up job would go on for an hour. created_at is the server's clock and now the browser's: a clock a few
//     minutes off only moves when the asking stops;
//   - a video this tab uploads that the pages loaded do not hold yet.
export function needsRefresh(
  pages: readonly ProfileVideoPage[] | undefined,
  awaitedIds: readonly string[],
  now: number,
): boolean {
  const awaited = new Set(awaitedIds);
  const videos = pages?.flatMap((page) => page.items) ?? [];
  const listed = new Set(videos.map((video) => video.video_id));
  return (
    videos.some(
      (video) =>
        video.status === "PROCESSING" ||
        (video.status === "UPLOADING" &&
          (awaited.has(video.video_id) || now - Date.parse(video.created_at) < uploadFormLifetimeMs)),
    ) || awaitedIds.some((id) => !listed.has(id))
  );
}

type Options = {
  // The videos of /me (every state) or of another user (READY only).
  list: "mine" | "user";
  userId: string;
  // Rendered by the server; without it the first page is fetched here.
  initialPage: ProfileVideoPage | undefined;
  // False holds the first request: the server was told to wait (429) and the client waits out the rest.
  enabled: boolean;
  // Videos of this tab's uploads, from the form until processing ends (needsRefresh).
  awaitedIds?: readonly string[];
};

// A profile's videos, page by page along `next_cursor`. The server renders the first page; the next ones come from
// /api/me/videos or /api/users/<id>/videos. The list is dropped from the cache when its page leaves (gcTime 0), so
// each visit shows the server's newer page rather than a kept one.
//
// "My videos" asks again every refreshIntervalMs while needsRefresh, and stops once it is not. React Query
// skips the interval while the tab is hidden and asks again when the tab comes back; a request still running is never
// doubled, it is the one the next tick waits for.
export function useVideoPages({ list, userId, initialPage, enabled, awaitedIds = [] }: Options) {
  // Read once, when the screen mounts: the server's page is fresh then.
  const [initialDataUpdatedAt] = useState(() => Date.now());
  return useInfiniteQuery({
    queryKey: ["profile", list, userId, "videos"],
    queryFn: ({ pageParam, signal }) =>
      list === "mine" ? fetchMyVideos(userId, pageParam, signal) : fetchUserVideos(userId, pageParam, signal),
    initialPageParam: "",
    getNextPageParam: (last: ProfileVideoPage) => last.next_cursor || undefined,
    // Spread rather than `initialData: undefined`: a present key, even undefined, types `data` as always defined.
    ...(initialPage ? { initialData: { pages: [initialPage], pageParams: [""] }, initialDataUpdatedAt } : {}),
    enabled,
    staleTime: refreshIntervalMs,
    gcTime: 0,
    refetchOnReconnect: false,
    refetchOnWindowFocus: list === "mine",
    // Judged again after every answer, so a form running out stops the asking at the next one.
    refetchInterval: (query) =>
      list === "mine" && needsRefresh(query.state.data?.pages, awaitedIds, Date.now()) ? refreshIntervalMs : false,
    retry: shouldRetry,
    retryDelay,
  });
}
