"use client";

import { Heart, Link2, Play } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { useEffect, useEffectEvent, useRef, useState, useSyncExternalStore } from "react";
import { preload } from "react-dom";
import type { RailFollow } from "@/components/feed/action-rail";
import { FeedItem } from "@/components/feed/feed-item";
import { LoginPrompt } from "@/components/feed/login-prompt";
import { primaryAction } from "@/components/shell/error-screen";
import { LinkPending } from "@/components/shell/link-pending";
import { useCountdown } from "@/components/shell/use-countdown";
import { Avatar, Button, Toast, ToastRegion } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { formatCompact } from "@/lib/format";
import { ApiError, copyShareLink, loginHref, recordView, type FeedItem as FeedItemData } from "./api";
import { isMediaUrl } from "./media-url";
import { ignoresShortcut, subscribeVisibility } from "./page-events";
import { PlayerPool, type PlaybackState } from "./player-pool";
import { useFollows } from "./use-follows";
import { useLike } from "./use-like";
import { useNow, usePublishedAgo } from "./use-now";
import { ViewCounter } from "./view-counter";

type ShareScreenProps = {
  // A READY video, checked by the server (server/video-page.ts).
  video: FeedItemData;
  // The logged-in user, null for a guest.
  viewerId: string | null;
  // MEDIA_ORIGIN of the server: the playlist and thumbnail are used only on this origin.
  mediaOrigin: string;
  // When the server got the video (ms since the epoch): the clock of "2 days ago" until the browser's takes over.
  loadedAt: number;
  // The server's "2 days ago" for the video, counted from `loadedAt`.
  renderedAgo?: string | null;
  appName: string;
};

type ToastState = { id: number; tone: "danger" | "success"; message: string; retry?: () => void };

const toastMs = 5000;

// Header links, button-like; literal so Tailwind finds them.
const headerLink =
  "inline-flex min-h-11 items-center rounded-md px-3 text-[15px] font-semibold text-foreground hover:bg-surface-hover hover:text-foreground md:px-4.5";

// The share page /v/{id} (web/design/SVP Mobile.dc.html
// M38, SVP Desktop.dc.html D04): one video played by the feed's player pool, its author, title and counts. A guest's
// like and follow ask them to log in and come back here, and their watching records no view; a logged-in user likes,
// follows and records a view after 2 s of playback as in the feed.
export function ShareScreen({ video, viewerId, mediaOrigin, loadedAt, renderedAgo, appName }: ShareScreenProps) {
  const t = useTranslations("feed");
  const s = useTranslations("share");
  const locale = useLocale();
  const router = useRouter();
  const guest = viewerId === null;
  const { author } = video;
  const pagePath = `/v/${video.video_id}`;
  const login = loginHref(pagePath);
  const register = `/register?next=${encodeURIComponent(pagePath)}`;
  // Profiles need a login: a guest sees the name without a link.
  const authorHref = author && !guest ? `/u/${author.handle}` : null;
  const publishedAgo = usePublishedAgo(
    useNow(loadedAt),
    renderedAgo === undefined ? undefined : { at: loadedAt, texts: { [video.published_at]: renderedAgo } },
  )(video.published_at);
  const posterUrl = isMediaUrl(video.thumbnail_url, mediaOrigin) ? video.thumbnail_url : null;
  // The poster is the page's largest paint: rendered on the server, this puts a high-priority preload in the <head>,
  // so the image starts before the scripts and fonts the page also asks for.
  if (posterUrl) {
    preload(posterUrl, { as: "image", fetchPriority: "high" });
  }

  const [playback, setPlayback] = useState<PlaybackState | undefined>(undefined);
  const [paused, setPaused] = useState(false);
  const [muted, setMuted] = useState(true);
  const [soundChosen, setSoundChosen] = useState(false);
  const [prompt, setPrompt] = useState<"like" | "follow" | null>(null);
  const [toast, setToast] = useState<ToastState | null>(null);
  // A like or follow got 429: both wait for its Retry-After, like the feed's.
  const [rateLimit, setRateLimit] = useState<{ seconds: number } | null>(null);
  const locked = useCountdown(rateLimit?.seconds ?? null, rateLimit) > 0;
  const hidden = useSyncExternalStore(
    subscribeVisibility,
    () => document.visibilityState === "hidden",
    () => false,
  );

  const stage = useRef<HTMLDivElement>(null);
  const pool = useRef<PlayerPool | null>(null);
  const views = useRef<ViewCounter | null>(null);
  const toastId = useRef(0);

  function showToast(tone: ToastState["tone"], message: string, retry?: () => void) {
    toastId.current += 1;
    setToast({ id: toastId.current, tone, message, retry });
  }

  function toLogin() {
    router.replace(login);
  }
  const redirectToLogin = useEffectEvent(toLogin);

  function actionFailed(error: unknown, message: string, retry?: () => void) {
    if (error instanceof ApiError && error.status === 401) {
      toLogin();
      return;
    }
    const rateLimited = error instanceof ApiError && error.status === 429;
    if (rateLimited) {
      setRateLimit({ seconds: error.retryAfterSeconds ?? 1 });
    }
    showToast("danger", rateLimited ? t("toast.rateLimited") : message, retry);
  }

  const like = useLike(video.video_id, video.stats, (error, wanted, retry) =>
    actionFailed(error, wanted ? t("toast.likeFailed") : t("toast.unlikeFailed"), retry),
  );
  // The gateway does not say whether the viewer follows the author, so the button starts as on Explore, not followed;
  // following someone already followed is harmless (PUT is idempotent).
  const follows = useFollows("explore", (error, wanted) =>
    actionFailed(error, wanted ? t("toast.followFailed") : t("toast.unfollowFailed")),
  );
  const follow: RailFollow | null =
    viewerId === video.author_id
      ? null
      : guest
        ? { following: false, pending: false, onToggle: () => setPrompt("follow") }
        : {
            following: follows.isFollowing(video.author_id),
            pending: follows.isPending(video.author_id),
            onToggle: () => follows.toggle(video.author_id),
          };
  const onLike = guest ? () => setPrompt("like") : like.toggle;

  function share() {
    copyShareLink(video.video_id).then(
      () => showToast("success", t("toast.linkCopied")),
      () => showToast("danger", t("toast.copyFailed")),
    );
  }

  // The pool lives as long as the page; its callbacks only set state and read refs.
  useEffect(() => {
    const created = new PlayerPool(mediaOrigin, {
      onState: (_index, state) => setPlayback(state),
      onTime: (_index, element) => {
        const bar = stage.current?.querySelector<HTMLElement>('[data-part="progress"]');
        if (bar && Number.isFinite(element.duration) && element.duration > 0) {
          const ratio = Math.min(element.currentTime / element.duration, 1);
          bar.style.scale = `${ratio} 1`;
          bar.parentElement?.setAttribute("aria-valuenow", String(Math.round(ratio * 100)));
        }
        views.current?.sample({
          currentTime: element.currentTime,
          playing: !element.paused,
          seeking: element.seeking,
          hidden: document.visibilityState === "hidden",
        });
      },
      onSeek: () => views.current?.interrupt(),
      onForcedMute: () => setMuted(true),
    });
    pool.current = created;
    return () => {
      created.destroy();
      pool.current = null;
    };
  }, [mediaOrigin]);

  const shouldPlay = !paused && !hidden;
  useEffect(() => {
    pool.current?.sync(
      0,
      [{ index: 0, playlistUrl: video.playlist_url }],
      () => stage.current?.querySelector<HTMLElement>('[data-part="video-host"]') ?? null,
      shouldPlay,
    );
  }, [video.playlist_url, shouldPlay]);

  // One view per page, only for a logged-in user. recordView rejects only when the session is refused (401).
  useEffect(() => {
    views.current = guest
      ? null
      : new ViewCounter(() => void recordView(video.video_id).catch(() => redirectToLogin()));
  }, [guest, video.video_id]);

  useEffect(() => {
    if (!toast || locked) {
      return;
    }
    const timer = setTimeout(() => setToast(null), toastMs);
    return () => clearTimeout(timer);
  }, [toast, locked]);

  // Sound changes inside the user's gesture: browsers refuse to unmute playing media outside one.
  function setSound(on: boolean) {
    pool.current?.setMuted(!on);
    setMuted(!on);
    setSoundChosen(true);
  }

  // The first tap on the video turns the sound on; later taps pause and resume.
  function onStageTap() {
    if (muted && !soundChosen) {
      setSound(true);
    } else {
      setPaused(!paused);
    }
  }

  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    if (prompt || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || ignoresShortcut(event)) {
      return;
    }
    if (event.key === " ") {
      event.preventDefault();
      setPaused(!paused);
    } else if (event.key === "m" || event.key === "M") {
      setSound(muted);
    }
  });
  useEffect(() => {
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const viewCount = video.stats?.view_count ?? null;
  const counts = [
    like.count === null ? null : t("likeCount", { count: formatCompact(like.count, locale) }),
    viewCount === null ? null : t("viewCount", { count: formatCompact(viewCount, locale) }),
    publishedAgo,
  ].filter((part) => part !== null);
  const authorName = author?.display_name;

  return (
    <div className="flex h-dvh flex-col bg-surface text-foreground">
      <header className="flex h-14 shrink-0 items-center justify-between border-b border-border pr-2 pl-4 md:h-16 md:px-6">
        <Link
          href="/"
          className={cn(
            "rounded-sm text-lg font-bold tracking-[0.1em] text-foreground hover:text-foreground md:text-[22px]",
            focusRing,
          )}
        >
          {appName}
          <LinkPending size={16} className="ml-2 inline" />
        </Link>
        {guest && (
          <nav className="flex gap-2">
            <Link href={login} className={cn(headerLink, focusRing)}>
              {s("logIn")}
            </Link>
            <Link
              href={register}
              className={cn(headerLink, "hidden border border-border-strong md:inline-flex", focusRing)}
            >
              {s("register")}
            </Link>
          </nav>
        )}
      </header>

      <main className="flex min-h-0 flex-1 flex-col md:flex-row md:items-center md:justify-center md:gap-6 md:p-6 lg:gap-10">
        <div
          ref={stage}
          className="relative min-h-0 flex-1 md:aspect-9/16 md:h-[min(780px,100%,calc((100vw_-_25rem)*16/9))] md:flex-none"
        >
          <FeedItem
            variant="share"
            index={0}
            title={video.title}
            authorId={video.author_id}
            author={author ? { displayName: author.display_name, handle: author.handle } : null}
            authorHref={authorHref}
            publishedAgo={publishedAgo}
            posterUrl={posterUrl}
            current
            playback={playback}
            pausedByUser={paused}
            muted={muted}
            showUnmuteHint={muted && !soundChosen}
            liked={like.liked}
            likeCount={like.count}
            viewCount={viewCount}
            follow={follow}
            locked={locked}
            onLike={onLike}
            onShare={share}
            onStageTap={onStageTap}
            onToggleMute={() => setSound(muted)}
            onRetry={() => pool.current?.retry(0)}
          />
        </div>

        {/* Wide screens: the author, title and actions beside the video (D04); on small ones they are over it. */}
        <aside className="hidden w-80 flex-col gap-6 md:flex lg:w-95">
          <div className="flex items-center gap-3.5">
            <Avatar seed={video.author_id} name={authorName} className="size-13" />
            <div className="flex min-w-0 flex-1 flex-col gap-0.5">
              {author && (
                <>
                  {authorHref ? (
                    <Link href={authorHref} className={cn("rounded-sm text-foreground hover:underline", focusRing)}>
                      <bdi className="text-[17px] font-semibold break-all">{author.display_name}</bdi>
                    </Link>
                  ) : (
                    <bdi className="text-[17px] font-semibold break-all">{author.display_name}</bdi>
                  )}
                  <span className="text-sm text-muted">@{author.handle}</span>
                </>
              )}
            </div>
            {follow && (
              <Button
                variant={follow.following ? "secondary" : "primary"}
                disabled={follow.pending || locked}
                onClick={follow.onToggle}
              >
                {follow.following ? s("following") : s("follow")}
              </Button>
            )}
          </div>
          <div className="flex flex-col gap-2.5">
            {video.title && (
              <h1 className="text-xl leading-[1.45] font-semibold text-pretty break-words">{video.title}</h1>
            )}
            {counts.length > 0 && <p className="text-sm text-muted">{counts.join(" · ")}</p>}
          </div>
          <div className="flex gap-2.5">
            {/* A toggle with one name; aria-pressed tells whether the video is liked. */}
            <Button variant="secondary" aria-pressed={like.liked} disabled={locked} onClick={onLike}>
              <Heart
                aria-hidden="true"
                size={20}
                className={cn(like.liked && "text-accent")}
                fill={like.liked ? "currentColor" : "none"}
              />
              {s("like")}
            </Button>
            <Button variant="secondary" onClick={share}>
              <Link2 aria-hidden="true" size={18} />
              {s("copyLink")}
            </Button>
          </div>
          <div className="flex flex-col gap-3.5 rounded-lg border border-border bg-surface-raised p-5">
            <strong className="text-base font-semibold">{s("moreTitle")}</strong>
            {guest && (
              <p className="text-sm leading-normal text-muted">
                {authorName ? s("moreBody", { name: authorName }) : s("moreBodyNoName")}
              </p>
            )}
            <Link href="/" className={cn(primaryAction, focusRing)}>
              <Play aria-hidden="true" size={18} />
              {s("openInApp")}
            </Link>
          </div>
        </aside>
      </main>

      <div className="flex shrink-0 flex-col gap-2 border-t border-border px-4 pt-3.5 pb-4.5 md:hidden">
        <Link href="/" className={cn(primaryAction, "min-h-13 text-base", focusRing)}>
          <Play aria-hidden="true" size={18} />
          {s("openInApp")}
        </Link>
        {guest && (
          // Room for two lines whether the hint takes one or two: a name near the end of a line can wrap in the
          // fallback font and not in the web font, and a bar that changed height when the font arrives would move
          // the video above it.
          <p className="min-h-10 content-center text-center text-sm text-muted">
            {authorName ? s("guestHint", { name: authorName }) : s("guestHintNoName")}
          </p>
        )}
      </div>

      <ToastRegion label={t("toast.region")} className="bottom-30 md:bottom-4">
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

      {prompt && (
        <LoginPrompt reason={prompt} loginHref={login} registerHref={register} onClose={() => setPrompt(null)} />
      )}
    </div>
  );
}
