import { CircleAlert, Play, RotateCw, Volume2, VolumeX } from "lucide-react";
import { useTranslations } from "next-intl";
import { Skeleton, Spinner } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { ActionRail, type RailFollow } from "./action-rail";
import { FeedTitle } from "./feed-title";

// What the player reports for the current item (features/feed/player-pool.ts).
export type ItemPlayback = "loading" | "playing" | "paused" | "buffering" | "error";

type FeedItemProps = {
  index: number;
  title: string;
  authorId: string;
  // Thumbnail already checked against the media origin; null shows the plain background.
  posterUrl: string | null;
  current: boolean;
  playback: ItemPlayback | undefined;
  pausedByUser: boolean;
  muted: boolean;
  showUnmuteHint: boolean;
  liked: boolean;
  likeCount: number | null;
  viewCount: number | null;
  follow: RailFollow | null;
  // A rate limit is running: like and follow wait for its Retry-After.
  locked: boolean;
  onLike: () => void;
  onStageTap: () => void;
  onToggleMute: () => void;
  onRetry: () => void;
};

// Overlay pills and scrims over video are fixed shades of black in both themes, like the white of on-media.
const pill = "bg-[oklch(0_0_0/0.4)]";

// One video of the vertical feed: the item fills the page box and snaps (web/design/FeedMobile.dc.html, rail layout;
// FeedDesktop.dc.html on wide screens: a 9:16 column with the actions beside it).
export function FeedItem({
  index,
  title,
  authorId,
  posterUrl,
  current,
  playback,
  pausedByUser,
  muted,
  showUnmuteHint,
  liked,
  likeCount,
  viewCount,
  follow,
  locked,
  onLike,
  onStageTap,
  onToggleMute,
  onRetry,
}: FeedItemProps) {
  const t = useTranslations("feed");
  const loading = current && (playback === undefined || playback === "loading");
  return (
    <article
      data-index={index}
      aria-label={title || undefined}
      className="relative flex h-full snap-start snap-always items-center justify-center md:gap-5 md:py-4 md:pl-23"
    >
      <div className="relative h-full w-full overflow-hidden bg-[oklch(0_0_0)] text-on-media md:aspect-9/16 md:w-auto md:shrink-0 md:rounded-lg">
        {posterUrl && (
          // A plain <img>: next/image always writes a style attribute, which the CSP (no 'unsafe-inline') blocks.
          // eslint-disable-next-line @next/next/no-img-element
          <img src={posterUrl} alt="" className="absolute inset-0 size-full object-cover" />
        )}
        {/* The player moves one of its <video> elements in here while the item is near the screen. */}
        <div data-part="video-host" className="absolute inset-0" />
        <button
          type="button"
          aria-label={pausedByUser ? t("play") : t("pause")}
          onClick={onStageTap}
          className="absolute inset-0 z-1 cursor-default outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset"
        />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 z-2 h-35 bg-[linear-gradient(to_bottom,oklch(0_0_0/0.55),oklch(0_0_0/0))] md:h-25"
        />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 bottom-0 z-2 h-85 bg-[linear-gradient(to_top,oklch(0_0_0/0.8),oklch(0_0_0/0.5)_50%,oklch(0_0_0/0))] md:h-65"
        />

        <button
          type="button"
          aria-label={muted ? t("unmute") : t("mute")}
          onClick={onToggleMute}
          className={cn(
            "absolute top-1.5 right-1.5 z-10 flex size-11 items-center justify-center rounded-full hover:bg-[oklch(0_0_0/0.55)] md:top-3 md:right-3",
            "bg-[oklch(0_0_0/0.35)]",
            focusRing,
          )}
        >
          {muted ? <VolumeX aria-hidden="true" size={20} /> : <Volume2 aria-hidden="true" size={20} />}
        </button>

        {current && showUnmuteHint && playback === "playing" && (
          <button
            type="button"
            onClick={onToggleMute}
            className={cn(
              "absolute top-16 left-1/2 z-4 flex min-h-11 -translate-x-1/2 items-center gap-2 rounded-full px-4 text-sm font-medium whitespace-nowrap",
              "bg-[oklch(0_0_0/0.55)]",
              focusRing,
            )}
          >
            <VolumeX aria-hidden="true" size={18} />
            {t("tapToUnmute")}
          </button>
        )}

        {loading && (
          <div
            role="status"
            aria-busy="true"
            aria-label={t("loading")}
            className="absolute inset-0 z-3 bg-[oklch(0_0_0/0.35)]"
          >
            <div className="absolute right-3 bottom-7 flex flex-col items-center gap-5.5 md:hidden">
              <Skeleton className="size-12 rounded-full" />
              <Skeleton className="size-10 rounded-full" />
              <Skeleton className="size-10 rounded-full" />
            </div>
            <div className="absolute bottom-7 left-4 flex flex-col gap-2.5">
              <Skeleton className="h-3.5 w-35 rounded-md" />
              <Skeleton className="h-3 w-65 max-w-[60vw] rounded-md" />
              <Skeleton className="h-3 w-47 max-w-[50vw] rounded-md" />
            </div>
          </div>
        )}

        {current && playback === "buffering" && (
          <span
            className={cn(
              "absolute top-1/2 left-1/2 z-3 flex size-16 -translate-1/2 items-center justify-center rounded-full",
              pill,
            )}
          >
            <Spinner size={32} label={t("loading")} />
          </span>
        )}

        {current && playback === "paused" && pausedByUser && (
          <div
            aria-hidden="true"
            className="pointer-events-none absolute top-1/2 left-1/2 z-3 flex -translate-1/2 flex-col items-center gap-3"
          >
            <span className="flex size-18 items-center justify-center rounded-full bg-[oklch(0_0_0/0.45)] md:size-20">
              <Play size={34} className="ml-1" />
            </span>
            <span className="hidden rounded-full bg-[oklch(0_0_0/0.55)] px-3 py-1.5 text-[13px] font-medium md:block">
              {t("paused")}
            </span>
          </div>
        )}

        {current && playback === "error" && (
          <div
            role="alert"
            className="absolute inset-0 z-5 flex flex-col items-center justify-center gap-3 bg-[oklch(0_0_0/0.6)] p-8 text-center"
          >
            <span className="flex size-14 items-center justify-center rounded-full bg-[oklch(1_0_0/0.12)]">
              <CircleAlert aria-hidden="true" size={28} />
            </span>
            <strong className="text-lg font-semibold">{t("playError.title")}</strong>
            <span className="max-w-65 text-[15px] leading-normal text-pretty text-on-media-muted">
              {t("playError.body")}
            </span>
            <button
              type="button"
              onClick={onRetry}
              className={cn(
                "mt-2 flex min-h-11 items-center gap-2 rounded-full bg-on-media px-5 text-[15px] leading-none font-semibold text-[oklch(0.18_0_0)]",
                focusRing,
              )}
            >
              <RotateCw aria-hidden="true" size={18} />
              {t("playError.retry")}
            </button>
          </div>
        )}

        <div className="absolute right-21 bottom-4.5 left-4 z-4 md:right-5 md:bottom-5.5 md:left-5">
          <FeedTitle title={title} />
        </div>

        <div
          role="progressbar"
          aria-label={t("progress")}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={0}
          className="pointer-events-none absolute inset-x-0 bottom-0 z-4 h-0.5 bg-[oklch(1_0_0/0.25)] md:h-0.75"
        >
          {/* The player sets its width and the bar's aria-valuenow on every timeupdate (CSSOM, not a style attribute the
              CSP blocks). */}
          <div data-part="progress" className="h-full origin-left scale-x-0 bg-on-media" />
        </div>
      </div>

      <ActionRail
        authorId={authorId}
        follow={follow}
        locked={locked}
        liked={liked}
        likeCount={likeCount}
        viewCount={viewCount}
        onLike={onLike}
      />
    </article>
  );
}
