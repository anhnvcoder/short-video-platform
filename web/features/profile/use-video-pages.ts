import { useInfiniteQuery } from "@tanstack/react-query";
import { useState } from "react";
import { retryDelay, shouldRetry } from "@/features/feed/api";
import { fetchMyVideos, fetchUserVideos, type ProfileVideoPage, type VideoStatus } from "./api";

// While a video of the list is still UPLOADING or PROCESSING, "My videos" asks for the list again this often, so the
// status changes and the thumbnail appears without a reload.
export const refreshIntervalMs = 5000;

const unfinished: ReadonlySet<VideoStatus> = new Set(["UPLOADING", "PROCESSING"]);

export function hasUnfinished(pages: readonly ProfileVideoPage[] | undefined): boolean {
  return pages?.some((page) => page.items.some((video) => unfinished.has(video.status))) ?? false;
}

// Whether a video the list should show is missing from the pages loaded.
function lacksAny(pages: readonly ProfileVideoPage[] | undefined, videoIds: readonly string[]): boolean {
  const listed = new Set(pages?.flatMap((page) => page.items.map((video) => video.video_id)));
  return videoIds.some((id) => !listed.has(id));
}

type Options = {
  // The videos of /me (every state) or of another user (READY only).
  list: "mine" | "user";
  userId: string;
  // Rendered by the server; without it the first page is fetched here.
  initialPage: ProfileVideoPage | undefined;
  // False holds the first request: the server was told to wait (429) and the client waits out the rest.
  enabled: boolean;
  // Videos of this tab's uploads: until the list holds them all, it asks again as for an unfinished video.
  awaitedIds?: readonly string[];
};

// A profile's videos, page by page along `next_cursor`. The server renders the first page; the next ones come from
// /api/me/videos or /api/users/<id>/videos. The list is dropped from the cache when its page leaves (gcTime 0), so
// each visit shows the server's newer page rather than a kept one.
//
// "My videos" asks again every refreshIntervalMs while a video is unfinished, and stops once none is. React Query
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
    refetchInterval: (query) =>
      list === "mine" && (hasUnfinished(query.state.data?.pages) || lacksAny(query.state.data?.pages, awaitedIds))
        ? refreshIntervalMs
        : false,
    retry: shouldRetry,
    retryDelay,
  });
}
