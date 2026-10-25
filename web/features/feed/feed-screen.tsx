"use client";

import { ChevronDown, ChevronUp, Link2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import {
  useEffect,
  useEffectEvent,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  useTransition,
  type ReactNode,
} from "react";
import { preload } from "react-dom";
import type { RailFollow } from "@/components/feed/action-rail";
import { FeedItem } from "@/components/feed/feed-item";
import { EmptyFeed, FeedEnd, FeedLoadError, FeedSkeleton, OfflineBanner } from "@/components/feed/feed-states";
import { useCountdown } from "@/components/shell/use-countdown";
import { IconButton, Toast, ToastRegion } from "@/components/ui";
import {
  ApiError,
  copyShareLink,
  loginHref,
  recordView,
  type FeedItem as FeedItemData,
  type FeedKind,
  type FeedPage,
} from "./api";
import { FeedFrame } from "./feed-frame";
import { isMediaUrl } from "./media-url";
import { ignoresShortcut, subscribeLoad, subscribeVisibility } from "./page-events";
import { PlayerPool, type PlaybackState } from "./player-pool";
import { useFeed } from "./use-feed";
import { useFollows } from "./use-follows";
import { useLike } from "./use-like";
import { useNow, usePublishedAgo } from "./use-now";
import { ViewCounter } from "./view-counter";

type FeedScreenProps = {
  kind: FeedKind;
  // First page rendered by the server; without it the client fetches it.
  initialPage?: FeedPage;
  // When the gateway gave the server that page (ms since the epoch): a page replayed by Back/Forward is old, and the
  // client fetches it again.
  initialPageFetchedAt?: number;
  // The gateway rate-limited the server's request for the first page: the client waits this long before its own.
  initialRetryAfterSeconds?: number;
  // MEDIA_ORIGIN of the server: playlist and thumbnail URLs are used only on this origin.
  mediaOrigin: string;
  // The logged-in user: no follow button on their own videos.
  currentUserId: string;
  // When the server rendered the page (ms since the epoch): the clock of "2 days ago" until the browser's takes over.
  renderedAt: number;
};

type ToastState = { id: number; tone: "danger" | "success"; message: string; retry?: () => void };

// Share of an item that must be on screen for it to become the current one.
const visibleRatio = 0.6;
const toastMs = 5000;

function subscribeOnline(onChange: () => void) {
  window.addEventListener("online", onChange);
  window.addEventListener("offline", onChange);
  return () => {
    window.removeEventListener("online", onChange);
    window.removeEventListener("offline", onChange);
  };
}

// A part of the item at `index` (components/feed/feed-item.tsx), looked up in the DOM when it is needed: the feed's
// children are the items in order, and a first page fetched again can move a video to another index.
function itemPart(feed: HTMLElement | null, index: number, part: "video-host" | "progress"): HTMLElement | null {
  return feed?.children.item(index)?.querySelector<HTMLElement>(`[data-part="${part}"]`) ?? null;
}

// The vertical feed: items snap one per screen, an IntersectionObserver picks
// the current one, and a pool of three players plays it and preloads its neighbours. Explore and Following share it.
export function FeedScreen({
  kind,
  initialPage,
  initialPageFetchedAt,
  initialRetryAfterSeconds,
  mediaOrigin,
  currentUserId,
  renderedAt,
}: FeedScreenProps) {
  const t = useTranslations("feed");
  const publishedAgo = usePublishedAgo(useNow(renderedAt));
  const router = useRouter();
  // Read from a deadline like the login page's countdown, so a page in the background never asks early.
  const firstWait = useCountdown(initialPage ? null : (initialRetryAfterSeconds ?? null), kind);
  const feed = useFeed(kind, initialPage, initialPageFetchedAt, firstWait === 0);
  const items = useMemo(() => feed.data?.pages.flatMap((page) => page.items) ?? [], [feed.data]);
  const itemCount = items.length;
  // The first poster is the page's largest paint: rendered on the server, this puts a high-priority preload in the
  // <head>, so the image starts before the scripts and fonts the page also asks for.
  const firstPoster = items[0]?.thumbnail_url;
  if (firstPoster && isMediaUrl(firstPoster, mediaOrigin)) {
    preload(firstPoster, { as: "image", fetchPriority: "high" });
  }

  const [current, setCurrent] = useState(0);
  // The item after the last video (end, next page loading or failed) can be current too: then nothing plays.
  const active = Math.min(current, itemCount);
  // That item is a new element for every length of the list (its key), so the browser cannot hold the old one on
  // screen when a page is inserted above it, and the observer never reports it at its new index. When it was the
  // current item as a page arrived, the page's first video takes over and is scrolled to (`jump`).
  const [listed, setListed] = useState<{ count: number; jump: number | null }>({ count: itemCount, jump: null });
  if (listed.count !== itemCount) {
    // An empty list has no such item: its first page is not a page after the last video.
    const tailWasCurrent = listed.count > 0 && itemCount > listed.count && current >= listed.count;
    setListed({ count: itemCount, jump: tailWasCurrent ? listed.count : null });
    if (tailWasCurrent) {
      setCurrent(listed.count);
    }
  }
  const [playback, setPlayback] = useState<Record<number, PlaybackState>>({});
  const [pausedIndex, setPausedIndex] = useState<number | null>(null);
  const [muted, setMuted] = useState(true);
  const [soundChosen, setSoundChosen] = useState(false);
  const [toast, setToast] = useState<ToastState | null>(null);
  // A like or follow got 429: every like and follow button, and the toast's retry, wait for its Retry-After. A new
  // object per refusal starts the wait again.
  const [rateLimit, setRateLimit] = useState<{ seconds: number } | null>(null);
  const locked = useCountdown(rateLimit?.seconds ?? null, rateLimit) > 0;
  const hidden = useSyncExternalStore(
    subscribeVisibility,
    () => document.visibilityState === "hidden",
    () => false,
  );
  const online = useSyncExternalStore(
    subscribeOnline,
    () => navigator.onLine,
    () => true,
  );
  // Neighbours render their posters only once the page has loaded: the next item sits inside the browser's lazy-load
  // margin, so its poster would otherwise download beside the current one, the page's largest paint.
  const loaded = useSyncExternalStore(
    subscribeLoad,
    () => document.readyState === "complete",
    () => false,
  );

  // The server renders a feed page with its first page (feed-route.tsx), so the router keeps this page until the other
  // tab's has arrived. Meanwhile that tab is shown selected, the skeleton lies over this feed and nothing plays: the
  // switch answers at once. The feed stays mounted under it, with its scroll position and players, in case the user
  // comes back before the other tab arrives.
  const [switching, startSwitch] = useTransition();
  const [switchTo, setSwitchTo] = useState(kind);
  const leaving = switching && switchTo !== kind;
  function selectTab(next: FeedKind) {
    setSwitchTo(next);
    startSwitch(() => router.push(next === "explore" ? "/" : "/following"));
  }

  const pool = useRef<PlayerPool | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const view = useRef<{ index: number; counter: ViewCounter } | null>(null);
  const toastId = useRef(0);

  function toLogin() {
    router.replace(loginHref(window.location.pathname + window.location.search));
  }
  const redirectToLogin = useEffectEvent(toLogin);

  function actionFailed(error: unknown, message: string, retry?: () => void) {
    if (error instanceof ApiError && error.status === 401) {
      toLogin();
      return;
    }
    toastId.current += 1;
    const rateLimited = error instanceof ApiError && error.status === 429;
    if (rateLimited) {
      setRateLimit({ seconds: error.retryAfterSeconds ?? 1 });
    }
    setToast({ id: toastId.current, tone: "danger", message: rateLimited ? t("toast.rateLimited") : message, retry });
  }

  function share(videoId: string) {
    copyShareLink(videoId).then(
      () => {
        toastId.current += 1;
        setToast({ id: toastId.current, tone: "success", message: t("toast.linkCopied") });
      },
      () => {
        toastId.current += 1;
        setToast({ id: toastId.current, tone: "danger", message: t("toast.copyFailed") });
      },
    );
  }

  const follows = useFollows(kind, (error, wanted) =>
    actionFailed(error, wanted ? t("toast.followFailed") : t("toast.unfollowFailed")),
  );

  // The pool lives as long as the screen; its callbacks only set state and read refs.
  useEffect(() => {
    const created = new PlayerPool(mediaOrigin, {
      onState: (index, state) =>
        setPlayback((previous) => (previous[index] === state ? previous : { ...previous, [index]: state })),
      onTime: (index, video) => {
        const bar = itemPart(scroller.current, index, "progress");
        if (bar && Number.isFinite(video.duration) && video.duration > 0) {
          const ratio = Math.min(video.currentTime / video.duration, 1);
          bar.style.scale = `${ratio} 1`;
          bar.parentElement?.setAttribute("aria-valuenow", String(Math.round(ratio * 100)));
        }
        const watching = view.current;
        if (watching?.index === index) {
          watching.counter.sample({
            currentTime: video.currentTime,
            playing: !video.paused,
            seeking: video.seeking,
            hidden: document.visibilityState === "hidden",
          });
        }
      },
      onSeek: (index) => {
        if (view.current?.index === index) {
          view.current.counter.interrupt();
        }
      },
      onForcedMute: () => setMuted(true),
    });
    pool.current = created;
    return () => {
      created.destroy();
      pool.current = null;
    };
  }, [mediaOrigin]);

  const sources = useMemo(
    () => items.map((item, index) => ({ index, playlistUrl: item.playlist_url, posterUrl: item.thumbnail_url })),
    [items],
  );
  const shouldPlay = pausedIndex !== active && !hidden && !leaving;
  useEffect(() => {
    pool.current?.sync(active, sources, (index) => itemPart(scroller.current, index, "video-host"), shouldPlay);
  }, [active, sources, shouldPlay]);

  // Every time an item becomes the current one is a new view, reported at most once. recordView rejects only when the
  // session is refused (401).
  const activeVideoId = items[active]?.video_id;
  useEffect(() => {
    view.current = activeVideoId
      ? {
          index: active,
          counter: new ViewCounter(() => void recordView(activeVideoId).catch(() => redirectToLogin())),
        }
      : null;
  }, [active, activeVideoId]);

  // Before the observer below is made again for the new list, so it finds the first new video on screen.
  useEffect(() => {
    if (listed.jump !== null) {
      scroller.current?.children.item(listed.jump)?.scrollIntoView({ block: "start", behavior: "instant" });
    }
  }, [listed]);

  // The feed's children are the items in order, the one after the last video included; each carries its index in
  // data-index, read when the observer reports it. Observed again whenever the list changes: a page adds items and a
  // new last item, and a first page fetched again can replace items.
  useEffect(() => {
    const root = scroller.current;
    if (!root || typeof IntersectionObserver === "undefined") {
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const index = Number((entry.target as HTMLElement).dataset.index);
          if (entry.isIntersecting && entry.intersectionRatio >= visibleRatio && Number.isInteger(index)) {
            setCurrent(index);
          }
        }
      },
      { root, threshold: visibleRatio },
    );
    for (const element of root.children) {
      observer.observe(element);
    }
    return () => observer.disconnect();
  }, [items]);

  const { hasNextPage, isFetching, isFetchingNextPage, isFetchNextPageError, fetchNextPage } = feed;
  useEffect(() => {
    // On one of the last two videos, so the next page is there before the user reaches the end; never from the item
    // after the last video. Not while any request of the feed runs: a next page would cancel the first page being
    // fetched again.
    if (hasNextPage && !isFetching && !isFetchNextPageError && active < itemCount && active >= itemCount - 2) {
      void fetchNextPage();
    }
  }, [active, itemCount, hasNextPage, isFetching, isFetchNextPageError, fetchNextPage]);

  // The page that failed last was refused with 429: its retry button waits for that Retry-After too.
  const loadError = feed.error instanceof ApiError ? feed.error : null;
  const loadRateLimited = loadError?.status === 429;
  const loadLocked = useCountdown(loadRateLimited ? (loadError.retryAfterSeconds ?? 1) : null, feed.error) > 0;

  const unauthorized = feed.error instanceof ApiError && feed.error.status === 401;
  useEffect(() => {
    if (unauthorized) {
      redirectToLogin();
    }
  }, [unauthorized]);

  // A toast stays while a rate limit runs, so its retry can show once the wait is over.
  useEffect(() => {
    if (!toast || locked) {
      return;
    }
    const timer = setTimeout(() => setToast(null), toastMs);
    return () => clearTimeout(timer);
  }, [toast, locked]);

  // Back online: a video that failed while offline loads again.
  const retryAfterReconnect = useEffectEvent(() => {
    if (playback[active] === "error") {
      pool.current?.retry(active);
    }
  });
  useEffect(() => {
    window.addEventListener("online", retryAfterReconnect);
    return () => window.removeEventListener("online", retryAfterReconnect);
  }, []);

  function go(index: number) {
    const target = scroller.current?.children.item(index);
    if (!target) {
      return;
    }
    const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    target.scrollIntoView({ block: "start", behavior: reduceMotion ? "auto" : "smooth" });
  }

  // Sound changes inside the user's gesture: browsers refuse to unmute playing media outside one.
  function setSound(on: boolean) {
    pool.current?.setMuted(!on);
    setMuted(!on);
    setSoundChosen(true);
  }

  function togglePause() {
    setPausedIndex(pausedIndex === active ? null : active);
  }

  // The first tap on a video turns the sound on; later taps pause and resume.
  function onStageTap() {
    if (muted && !soundChosen) {
      setSound(true);
    } else {
      togglePause();
    }
  }

  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    // While leaving for the other tab, this feed is under the skeleton: no shortcut acts on what cannot be seen.
    if (leaving || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || ignoresShortcut(event)) {
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      go(event.key === "ArrowDown" ? active + 1 : active - 1);
    } else if (event.key === " ") {
      event.preventDefault();
      if (active < items.length) {
        togglePause();
      }
    } else if (event.key === "m" || event.key === "M") {
      setSound(muted);
    }
  });
  useEffect(() => {
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  let body: ReactNode;
  if (feed.status === "pending" || unauthorized) {
    body = <FeedSkeleton />;
  } else if (items.length === 0) {
    body = feed.isError ? (
      <FeedLoadError rateLimited={loadRateLimited} locked={loadLocked} onRetry={() => void feed.refetch()} />
    ) : (
      <EmptyFeed kind={kind} />
    );
  } else {
    // A retry of a failed page keeps its error until it ends; the item shows it loading meanwhile, so the button cannot
    // send the request again.
    const tail = !hasNextPage ? (
      <FeedEnd kind={kind} onRestart={() => go(0)} />
    ) : isFetchNextPageError && !isFetchingNextPage ? (
      <FeedLoadError rateLimited={loadRateLimited} locked={loadLocked} onRetry={() => void fetchNextPage()} />
    ) : (
      <FeedSkeleton />
    );
    body = (
      <div
        ref={scroller}
        role="feed"
        aria-label={t("feedLabel")}
        aria-busy={isFetchingNextPage}
        className="h-full snap-y snap-mandatory overflow-y-auto overscroll-y-contain [scrollbar-width:none]"
      >
        {items.map((item, index) => (
          <FeedEntry
            key={item.video_id}
            item={item}
            index={index}
            current={index === active}
            nearby={index === active || (loaded && Math.abs(index - active) === 1)}
            playback={playback[index]}
            pausedByUser={pausedIndex === index}
            muted={muted}
            showUnmuteHint={muted && !soundChosen}
            mediaOrigin={mediaOrigin}
            publishedAgo={publishedAgo(item.published_at)}
            follow={
              item.author_id === currentUserId
                ? null
                : {
                    following: follows.isFollowing(item.author_id),
                    pending: follows.isPending(item.author_id),
                    onToggle: () => follows.toggle(item.author_id),
                  }
            }
            locked={locked}
            onLikeError={(error, wanted, retry) =>
              actionFailed(error, wanted ? t("toast.likeFailed") : t("toast.unlikeFailed"), retry)
            }
            onShare={() => share(item.video_id)}
            onStageTap={onStageTap}
            onToggleMute={() => setSound(muted)}
            onRetry={() => pool.current?.retry(index)}
          />
        ))}
        <article
          key={`tail-${items.length}`}
          data-index={items.length}
          className="h-full snap-start snap-always bg-surface"
        >
          {tail}
        </article>
      </div>
    );
  }

  return (
    <FeedFrame
      kind={leaving ? switchTo : kind}
      onSelect={selectTab}
      overlays={
        <>
          {!online && <OfflineBanner />}
          {items.length > 0 && !leaving && (
            <div className="absolute top-1/2 right-8 z-20 hidden -translate-y-1/2 flex-col gap-3 md:flex">
              <IconButton
                label={t("previous")}
                icon={<ChevronUp aria-hidden="true" size={22} />}
                disabled={active === 0}
                onClick={() => go(active - 1)}
                className="size-12 border border-border bg-surface-raised hover:bg-surface-hover"
              />
              <IconButton
                label={t("next")}
                icon={<ChevronDown aria-hidden="true" size={22} />}
                disabled={active >= items.length}
                onClick={() => go(active + 1)}
                className="size-12 border border-border bg-surface-raised hover:bg-surface-hover"
              />
            </div>
          )}
          <ToastRegion label={t("toast.region")} className="bottom-20 md:bottom-4">
            {toast && (
              <Toast
                key={toast.id}
                tone={toast.tone}
                icon={toast.tone === "success" ? Link2 : undefined}
                action={
                  toast.retry && !locked
                    ? {
                        label: t("toast.retry"),
                        onClick: () => {
                          toast.retry?.();
                          setToast(null);
                        },
                      }
                    : undefined
                }
              >
                {toast.message}
              </Toast>
            )}
          </ToastRegion>
        </>
      }
    >
      {/* Under the skeleton while leaving for the other tab: inert keeps the keyboard and screen readers out of a feed
          that cannot be seen, so Tab and Enter never like or follow a video the user does not see. */}
      <div inert={leaving} className="h-full">
        {body}
      </div>
      {leaving && (
        <div className="absolute inset-0 z-10">
          <FeedSkeleton />
        </div>
      )}
    </FeedFrame>
  );
}

type FeedEntryProps = {
  item: FeedItemData;
  index: number;
  current: boolean;
  // The current item, or a neighbour in the window of the player pool once the page has loaded: only these render their
  // poster, so a page of ten videos does not download ten images on load.
  nearby: boolean;
  playback: PlaybackState | undefined;
  pausedByUser: boolean;
  muted: boolean;
  showUnmuteHint: boolean;
  mediaOrigin: string;
  publishedAgo: string | null;
  follow: RailFollow | null;
  locked: boolean;
  onLikeError: (error: unknown, wanted: boolean, retry: () => void) => void;
  onShare: () => void;
  onStageTap: () => void;
  onToggleMute: () => void;
  onRetry: () => void;
};

// One item with its own like state.
function FeedEntry({ item, mediaOrigin, nearby, onLikeError, ...props }: FeedEntryProps) {
  const like = useLike(item.video_id, item.stats, onLikeError);
  return (
    <FeedItem
      {...props}
      title={item.title}
      authorId={item.author_id}
      author={item.author ? { displayName: item.author.display_name, handle: item.author.handle } : null}
      authorHref={item.author ? `/u/${item.author.handle}` : null}
      posterUrl={nearby && isMediaUrl(item.thumbnail_url, mediaOrigin) ? item.thumbnail_url : null}
      liked={like.liked}
      likeCount={like.count}
      viewCount={item.stats?.view_count ?? null}
      onLike={like.toggle}
    />
  );
}
