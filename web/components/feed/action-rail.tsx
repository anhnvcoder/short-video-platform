import { Check, Eye, Heart, Plus, Share } from "lucide-react";
import { useLocale, useTranslations } from "next-intl";
import { Avatar } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { formatCompact } from "@/lib/format";

export type RailFollow = { following: boolean; pending: boolean; onToggle: () => void };

type ActionRailProps = {
  authorId: string;
  // Display name of the author, for the avatar's initial; without it a person icon.
  authorName?: string;
  // Null on the caller's own videos: no follow button.
  follow: RailFollow | null;
  // A rate limit is running: like and follow wait for its Retry-After.
  locked: boolean;
  liked: boolean;
  // Null when the feed came without stats: the counts are hidden, never shown as 0.
  likeCount: number | null;
  viewCount: number | null;
  onLike: () => void;
  // Copies the video's share link.
  onShare: () => void;
};

// Over the video at the bottom right on small screens (FeedMobile, rail layout); beside the video on wide screens
// (FeedDesktop).
export function ActionRail({
  authorId,
  authorName,
  follow,
  locked,
  liked,
  likeCount,
  viewCount,
  onLike,
  onShare,
}: ActionRailProps) {
  const t = useTranslations("feed");
  const locale = useLocale();
  const label = "text-[13px] font-semibold text-shadow-media md:text-shadow-none";
  // A toggle: its name stays the same in both states and aria-pressed alone tells whether the video is liked, so a
  // screen reader never reads "Unlike video, pressed". The name holds the text the button shows (WCAG 2.5.3), so a
  // user who says what they see can press it: the count after the action, or, without stats, "Like" in the action.
  const shownLikes = likeCount === null ? null : formatCompact(likeCount, locale);
  const likeName = shownLikes === null ? t("like") : t("likeWithCount", { count: shownLikes });
  return (
    <div className="absolute right-1 bottom-4 z-10 flex w-16 flex-col items-center gap-2.5 text-on-media md:static md:w-18 md:gap-4.5 md:self-end md:pb-1 md:text-foreground">
      {follow ? (
        <button
          type="button"
          aria-label={follow.following ? t("unfollow") : t("follow")}
          disabled={follow.pending || locked}
          onClick={follow.onToggle}
          className={cn("relative flex h-16 w-14 justify-center rounded-full disabled:opacity-60", focusRing)}
        >
          <Avatar seed={authorId} name={authorName} className="border-2 border-on-media md:size-13 md:border-0" />
          <span
            aria-hidden="true"
            className={cn(
              "absolute bottom-1 left-1/2 flex size-6 -translate-x-1/2 items-center justify-center rounded-full md:border-2 md:border-surface",
              follow.following ? "bg-on-media text-surface" : "bg-accent text-accent-foreground",
            )}
          >
            {follow.following ? <Check size={15} /> : <Plus size={16} />}
          </span>
        </button>
      ) : (
        <Avatar
          seed={authorId}
          name={authorName}
          label={t("author")}
          className="border-2 border-on-media md:size-13 md:border-0"
        />
      )}

      <button
        type="button"
        aria-pressed={liked}
        aria-label={likeName}
        disabled={locked}
        onClick={onLike}
        className={cn(
          "flex min-h-14 w-14 flex-col items-center gap-0.5 rounded-md py-1 transition-transform duration-120 ease-out active:scale-90 disabled:opacity-60",
          focusRing,
        )}
      >
        <span className="flex size-8 items-center justify-center md:size-13 md:rounded-full md:bg-surface-raised md:hover:bg-surface-hover">
          <Heart
            aria-hidden="true"
            className={cn("size-8 drop-shadow-media md:size-6.5 md:drop-shadow-none", liked && "text-accent")}
            fill={liked ? "currentColor" : "none"}
          />
        </span>
        <span className={label}>{shownLikes ?? t("likeText")}</span>
      </button>

      {viewCount !== null && (
        <div
          role="img"
          aria-label={t("viewCount", { count: formatCompact(viewCount, locale, "long") })}
          className="flex min-h-13 w-14 flex-col items-center justify-center gap-0.5"
        >
          <span className="flex size-8 items-center justify-center md:size-13 md:text-muted">
            <Eye aria-hidden="true" className="size-7 drop-shadow-media md:size-6 md:drop-shadow-none" />
          </span>
          <span className={label}>{formatCompact(viewCount, locale)}</span>
        </div>
      )}

      <button
        type="button"
        aria-label={t("shareLabel")}
        onClick={onShare}
        className={cn("flex min-h-14 w-14 flex-col items-center gap-0.5 rounded-md py-1", focusRing)}
      >
        <span className="flex size-8 items-center justify-center md:size-13 md:rounded-full md:bg-surface-raised md:hover:bg-surface-hover">
          <Share aria-hidden="true" className="size-7 drop-shadow-media md:size-5.5 md:drop-shadow-none" />
        </span>
        <span className={label}>{t("share")}</span>
      </button>
    </div>
  );
}
