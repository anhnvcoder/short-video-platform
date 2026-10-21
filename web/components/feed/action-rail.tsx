import { Check, Eye, Heart, Plus } from "lucide-react";
import { useLocale, useTranslations } from "next-intl";
import { Avatar } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { formatCompact } from "@/lib/format";

export type RailFollow = { following: boolean; pending: boolean; onToggle: () => void };

type ActionRailProps = {
  authorId: string;
  // Null on the caller's own videos: no follow button.
  follow: RailFollow | null;
  // A rate limit is running: like and follow wait for its Retry-After.
  locked: boolean;
  liked: boolean;
  // Null when the feed came without stats: the counts are hidden, never shown as 0.
  likeCount: number | null;
  viewCount: number | null;
  onLike: () => void;
};

// Over the video at the bottom right on small screens (FeedMobile, rail layout); beside the video on wide screens
// (FeedDesktop). Part A has no share button.
export function ActionRail({ authorId, follow, locked, liked, likeCount, viewCount, onLike }: ActionRailProps) {
  const t = useTranslations("feed");
  const locale = useLocale();
  const label = "text-[13px] font-semibold text-shadow-media md:text-shadow-none";
  // The like button's name holds the text it shows (WCAG 2.5.3), so a user who says what they see can press it: the
  // count after the action, or, without stats, "Like" in the action itself, with aria-pressed telling the state (an
  // "Unlike video" name would not hold the "Like" it shows).
  const shownLikes = likeCount === null ? null : formatCompact(likeCount, locale);
  const likeName =
    shownLikes === null ? t("like") : t(liked ? "unlikeWithCount" : "likeWithCount", { count: shownLikes });
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
          <Avatar seed={authorId} className="border-2 border-on-media md:size-13 md:border-0" />
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
        <Avatar seed={authorId} label={t("author")} className="border-2 border-on-media md:size-13 md:border-0" />
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
    </div>
  );
}
