import {
  matchMutation,
  useMutation,
  useQueryClient,
  type InfiniteData,
  type Mutation,
  type QueryClient,
} from "@tanstack/react-query";
import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import { setLiked, type FeedPage, type VideoStats } from "./api";

export interface LikeToggle {
  liked: boolean;
  // Null when the feed came without stats: the count is hidden, never shown as 0.
  count: number | null;
  toggle(): void;
}

type OnLikeError = (error: unknown, wanted: boolean, retry: () => void) => void;

// One tap on the like button: a mutation of the tab's query client, so it outlives the screen it was made on.
type LikeTap = {
  liked: boolean;
  // Sent even when the server is known to be in that state: a retry after a failure, whose request may have been
  // applied before the answer was lost (PUT and DELETE are safe to repeat).
  force: boolean;
  // Made while an earlier tap of the video was still pending: it waits for that one and may need no request at all.
  queued: boolean;
  // Tells the screen of the tap that the like failed, with a function that asks for this state again.
  report(error: unknown): void;
};

type LikeMutation = Mutation<boolean | undefined, unknown, LikeTap>;

const likeKey = (videoId: string) => ["like", videoId];

// Taps still waiting when a request before them failed: they end without a request, and the failure is reported with
// the state of the last of them, as one.
const dropped = new WeakSet<LikeTap>();

// The like mutations of a video in this tab, oldest first (the cache keeps them in the order they were made).
function tapsOf(client: QueryClient, videoId: string): LikeMutation[] {
  return client.getMutationCache().findAll({ mutationKey: likeKey(videoId), exact: true }) as LikeMutation[];
}

// The state of the last tap still to be sent or answered; undefined when there is none.
function pendingState(client: QueryClient, videoId: string): boolean | undefined {
  return tapsOf(client, videoId)
    .map((tap) => tap.state)
    .filter(({ status, variables }) => status === "pending" && variables && !dropped.has(variables))
    .at(-1)?.variables?.liked;
}

// The server's state after the taps before `index`: the result of the last one that had one, undefined when that one
// failed (the server may or may not have applied it). Taps that left their turn to a later one have no result.
function stateBefore(taps: LikeMutation[], index: number): boolean | undefined {
  for (let i = index - 1; i >= 0; i--) {
    const { status, data } = taps[i]?.state ?? {};
    if (status === "error") {
      return undefined;
    }
    if (data !== undefined) {
      return data;
    }
  }
  return undefined;
}

// Runs once the taps before it have ended (one request per video at a time). A tap made while nothing was pending is
// sent at once. Taps made behind it, faster than the server, are merged: one followed by another one still waiting
// leaves its turn to it, and the last one sends nothing when the requests before it left the server in its state. Resolves with the state the server is in afterwards, undefined
// when the tap sent nothing and knows nothing.
async function sendTap(client: QueryClient, videoId: string, tap: LikeTap): Promise<boolean | undefined> {
  const taps = tapsOf(client, videoId);
  const index = taps.findIndex((mutation) => mutation.state.variables === tap);
  if (
    dropped.has(tap) ||
    (tap.queued && taps.slice(index + 1).some((mutation) => mutation.state.status === "pending"))
  ) {
    return undefined;
  }
  if (tap.queued && !tap.force && stateBefore(taps, index) === tap.liked) {
    return tap.liked;
  }
  await setLiked(videoId, tap.liked);
  return tap.liked;
}

function withLike(stats: VideoStats, liked: boolean): VideoStats {
  return stats.liked_by_me === liked
    ? stats
    : { ...stats, liked_by_me: liked, like_count: Math.max(0, stats.like_count + (liked ? 1 : -1)) };
}

// Writes the state the server confirmed into every feed of the cache that holds the video.
function storeLike(client: QueryClient, videoId: string, liked: boolean) {
  client.setQueriesData<InfiniteData<FeedPage>>({ queryKey: ["feed"] }, (feed) =>
    feed
      ? {
          ...feed,
          pages: feed.pages.map((page) => ({
            ...page,
            items: page.items.map((item) =>
              item.video_id === videoId && item.stats ? { ...item, stats: withLike(item.stats, liked) } : item,
            ),
          })),
        }
      : feed,
  );
}

// A feed page still being read when a like request ends may have been read before the server applied it, and would
// land over the state just stored: it is read again (the read in flight is cancelled). Back and Forward start such a
// read as the screen mounts. Next pages are left alone: a refetch reloads every page of the feed, and the video
// liked is on a page already shown.
function rereadPagesInFlight(client: QueryClient) {
  void client.invalidateQueries({
    queryKey: ["feed"],
    predicate: (query) => query.state.fetchStatus === "fetching" && !query.state.fetchMeta?.fetchMore,
  });
}

// Optimistic like of one video. The button changes at once; the server is brought to the state of the last tap by one
// request at a time, so taps in quick succession never race each other and the end state is always the last tap's.
// A failed request puts the button back to the server's state and calls `onError` with the state of the last tap and
// a function that asks for that state again.
//
// The taps live in the tab's query client rather than in the screen: while one is pending, every screen of the video
// shows it, also a screen mounted later (Back and Forward replay a page read before the tap). Once its request has
// ended, the server's answer is stored into the cached feeds and the screen that showed the tap keeps it; stats read
// after that show as they come.
export function useLike(videoId: string, stats: VideoStats | undefined, onError: OnLikeError): LikeToggle {
  const client = useQueryClient();
  const { mutate } = useMutation({
    mutationKey: likeKey(videoId),
    scope: { id: `like:${videoId}` },
    // Offline, the request fails at once and says so, instead of waiting for the network.
    networkMode: "always",
    mutationFn: (tap: LikeTap) => sendTap(client, videoId, tap),
    onSuccess: (liked) => {
      if (liked !== undefined) {
        storeLike(client, videoId, liked);
      }
    },
    onError: (error, failed) => {
      const waiting = tapsOf(client, videoId)
        .map((tap) => tap.state)
        .filter(({ status, variables }) => status === "pending" && variables && variables !== failed)
        .map(({ variables }) => variables as LikeTap);
      for (const tap of waiting) {
        dropped.add(tap);
      }
      (waiting.at(-1) ?? failed).report(error);
    },
    onSettled: (liked, error) => {
      if (liked !== undefined || error) {
        rereadPagesInFlight(client);
      }
    },
  });

  // The tab's taps of the video, on any screen. Read from the mutation cache, which tells its listeners at once: the
  // button changes in the same render as the tap.
  const subscribe = useCallback((listener: () => void) => client.getMutationCache().subscribe(listener), [client]);
  const pending = useSyncExternalStore(
    subscribe,
    () => pendingState(client, videoId),
    () => undefined,
  );

  // The server's answer to a request that ended while this screen showed `over`: newer than those stats.
  const [answer, setAnswer] = useState<{ over: VideoStats | undefined; liked: boolean }>();
  useEffect(
    () =>
      client.getMutationCache().subscribe((event) => {
        if (
          event.type === "updated" &&
          event.action.type === "success" &&
          event.mutation.state.data !== undefined &&
          matchMutation({ mutationKey: likeKey(videoId), exact: true }, event.mutation)
        ) {
          setAnswer({ over: stats, liked: event.mutation.state.data as boolean });
        }
      }),
    [client, videoId, stats],
  );

  const settled = answer && answer.over === stats ? answer.liked : (stats?.liked_by_me ?? false);
  const liked = pending ?? settled;

  function send(state: boolean, force: boolean) {
    const queued = tapsOf(client, videoId).some((tap) => tap.state.status === "pending");
    mutate({ liked: state, force, queued, report: (error) => onError(error, state, () => send(state, true)) });
  }

  // The count without the caller's own like, plus the like the button shows. Counts lag, so never below zero.
  const count = stats ? Math.max(0, stats.like_count - (stats.liked_by_me ? 1 : 0) + (liked ? 1 : 0)) : null;
  // Read from the cache rather than from this render: several taps can come before the next one.
  return { liked, count, toggle: () => send(!(pendingState(client, videoId) ?? settled), false) };
}
