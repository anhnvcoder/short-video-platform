import { useInfiniteQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { fetchFeedPage, retryDelay, shouldRetry, type FeedKind, type FeedPage } from "./api";

// How long a first page counts as fresh after the screen mounted with it. It only has to cover the mount itself: the
// feed is never refetched behind the user's back, and a replayed page is marked stale from the start (below).
const firstPageFreshMs = 5000;

// The first pages this tab has already shown, by feed and the server's `fetchedAt` stamp. The stamp is only a name for
// one server render, never compared with the browser's clock (the two clocks can be minutes apart). Each tab loads its
// own copy of this module, so tabs do not share it. The oldest names go once there are more than `seenLimit`.
const seenLimit = 50;
const seenPages = new Set<string>();

function remember(page: string) {
  seenPages.delete(page);
  seenPages.add(page);
  for (const oldest of seenPages) {
    if (seenPages.size <= seenLimit) {
      break;
    }
    seenPages.delete(oldest);
  }
}

// One feed, page by page along `next_cursor`. The server renders the first page and hands it over as `initialPage`,
// stamped with the time the gateway gave it (`fetchedAt`); the next pages come from /api/feed/<kind>. A feed is not
// refetched behind the user's back (window focus, reconnect): that would reload every page and move the list under
// the video being watched.
//
// The feed is dropped from the cache as soon as its screen leaves (gcTime 0). The page is dynamic, so every visit
// renders a new first page on the server; `initialData` only seeds an empty cache, so a kept feed would hide that newer
// page (likes made since, new videos) behind the old one. Without a kept feed, the server's page is always the one shown.
//
// Browser Back/Forward does not render the page again: the router replays the payload it kept from the first visit, so
// the page it hands over can be old, even a second old with a like made on it since. Such a page carries a stamp this
// tab has already shown: it starts stale, and React Query fetches the first page again in the background, which
// replaces the old one. A stamp not seen yet is a new server render: it counts as fresh from the mount, so it is not
// asked for twice.
//
// `enabled` false holds the first request: the server was told to wait (429) and the client waits out the rest.
export function useFeed(
  kind: FeedKind,
  initialPage: FeedPage | undefined,
  fetchedAt: number | undefined,
  enabled: boolean,
) {
  const page = fetchedAt === undefined ? null : `${kind}:${fetchedAt}`;
  // Read once, when the screen mounts. The page is remembered only once the mount is committed (the effect): React
  // can render a component more than once before that (StrictMode in development, a render it throws away), and those
  // renders must not take the page for a replay.
  const [initialDataUpdatedAt] = useState(() => (page !== null && seenPages.has(page) ? 0 : Date.now()));
  useEffect(() => {
    if (page !== null) {
      remember(page);
    }
  }, [page]);

  return useInfiniteQuery({
    queryKey: ["feed", kind],
    queryFn: ({ pageParam, signal }) => fetchFeedPage(kind, pageParam, signal),
    initialPageParam: "",
    getNextPageParam: (last: FeedPage) => last.next_cursor || undefined,
    // Spread rather than `initialData: undefined`: a present key, even undefined, types `data` as always defined.
    ...(initialPage ? { initialData: { pages: [initialPage], pageParams: [""] }, initialDataUpdatedAt } : {}),
    enabled,
    staleTime: firstPageFreshMs,
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: shouldRetry,
    retryDelay,
  });
}
