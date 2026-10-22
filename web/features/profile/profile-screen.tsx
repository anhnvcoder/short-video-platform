"use client";

import { Link2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { useEffect, useEffectEvent, useMemo, useRef, useState, type ReactNode } from "react";
import { ProfileHeader } from "@/components/profile/profile-header";
import { EmptyProfileVideos, GridSkeleton, VideosFailed } from "@/components/profile/profile-states";
import { VideoGrid, type GridVideo } from "@/components/profile/video-grid";
import { useCountdown } from "@/components/shell/use-countdown";
import { Button, Toast, ToastRegion } from "@/components/ui";
import { ApiError, loginHref } from "@/features/feed/api";
import { isMediaUrl } from "@/features/feed/media-url";
import { formatDuration } from "@/features/upload/format";
import { formatCompact } from "@/lib/format";
import { copyProfileLink, profileHref, type ProfileVideoPage, type ShownProfile } from "./api";
import { useFollow } from "./use-follow";
import { useVideoPages } from "./use-video-pages";

type ProfileScreenProps = {
  // Checked by the server (server/profile-page.ts): never the viewer's own.
  profile: ShownProfile;
  initialPage: ProfileVideoPage | undefined;
  // Set when the server's request got 429 and no page: the first request waits this long.
  initialRetryAfterSeconds?: number;
  // MEDIA_ORIGIN of the server: thumbnails are shown only from there.
  mediaOrigin: string;
};

type ToastState = { id: number; tone: "danger" | "success"; message: string };

const toastMs = 5000;

// Another user's profile (/u/<handle>; web/design/SVP Mobile.dc.html M35–M37, SVP Desktop.dc.html D10): who they are,
// whether the viewer follows them, and their READY videos in a grid.
export function ProfileScreen({ profile, initialPage, initialRetryAfterSeconds, mediaOrigin }: ProfileScreenProps) {
  const t = useTranslations("profile");
  const locale = useLocale();
  const router = useRouter();
  const pagePath = profileHref(profile.handle);
  const name = profile.displayName;

  const [toast, setToast] = useState<ToastState | null>(null);
  // A follow change got 429: the button waits for its Retry-After.
  const [rateLimit, setRateLimit] = useState<{ seconds: number } | null>(null);
  const locked = useCountdown(rateLimit?.seconds ?? null, rateLimit) > 0;
  const toastId = useRef(0);

  function showToast(tone: ToastState["tone"], message: string) {
    toastId.current += 1;
    setToast({ id: toastId.current, tone, message });
  }

  function toLogin() {
    router.replace(loginHref(pagePath));
  }
  const redirectToLogin = useEffectEvent(toLogin);

  const follow = useFollow(profile.userId, profile.followedByMe, (error, wanted) => {
    if (error instanceof ApiError && error.status === 401) {
      toLogin();
      return;
    }
    const rateLimited = error instanceof ApiError && error.status === 429;
    if (rateLimited) {
      setRateLimit({ seconds: error.retryAfterSeconds ?? 1 });
    }
    showToast(
      "danger",
      rateLimited
        ? t("toast.rateLimited")
        : wanted
          ? t("toast.followFailed", { name })
          : t("toast.unfollowFailed", { name }),
    );
  });

  function copyLink() {
    copyProfileLink(profile.handle).then(
      () => showToast("success", t("toast.linkCopied")),
      () => showToast("danger", t("toast.copyFailed")),
    );
  }

  // Back where the user came from; a profile opened from outside the app has nowhere to go back to in it.
  function back() {
    if (window.history.length > 1) {
      router.back();
    } else {
      router.push("/");
    }
  }

  useEffect(() => {
    if (!toast || locked) {
      return;
    }
    const timer = setTimeout(() => setToast(null), toastMs);
    return () => clearTimeout(timer);
  }, [toast, locked]);

  // Read from a deadline like the login page's countdown, so a page in the background never asks early.
  const firstWait = useCountdown(initialPage ? null : (initialRetryAfterSeconds ?? null), profile.userId);
  const videos = useVideoPages({ list: "user", userId: profile.userId, initialPage, enabled: firstWait === 0 });
  const tiles = useMemo<GridVideo[]>(() => {
    const seen = new Set<string>();
    return (videos.data?.pages.flatMap((page) => page.items) ?? [])
      .filter(
        (video) => video.status === "READY" && (seen.has(video.video_id) ? false : (seen.add(video.video_id), true)),
      )
      .map((video) => ({
        id: video.video_id,
        href: `/v/${video.video_id}`,
        title: video.title || t("untitled"),
        thumbnailUrl: video.thumbnail_url && isMediaUrl(video.thumbnail_url, mediaOrigin) ? video.thumbnail_url : null,
        views: video.view_count === undefined ? null : formatCompact(video.view_count, locale),
        duration: video.duration_ms === undefined ? null : formatDuration(video.duration_ms / 1000),
      }));
  }, [videos.data, mediaOrigin, locale, t]);

  const loadError = videos.error instanceof ApiError ? videos.error : null;
  const retryIn = useCountdown(loadError?.status === 429 ? (loadError.retryAfterSeconds ?? 1) : null, videos.error);
  const unauthorized = loadError?.status === 401;
  useEffect(() => {
    if (unauthorized) {
      redirectToLogin();
    }
  }, [unauthorized]);

  let content: ReactNode;
  if (tiles.length > 0) {
    content = (
      <>
        <VideoGrid label={t("other.videosLabel", { name })} videos={tiles} />
        {videos.isFetchNextPageError ? (
          <VideosFailed retryIn={retryIn} onRetry={() => void videos.fetchNextPage()} />
        ) : (
          videos.hasNextPage && (
            <Button
              variant="secondary"
              loading={videos.isFetchingNextPage}
              onClick={() => void videos.fetchNextPage()}
              className="m-4 self-center"
            >
              {t("loadMore")}
            </Button>
          )
        )}
      </>
    );
  } else if (videos.data) {
    content = <EmptyProfileVideos name={name} />;
  } else if (videos.isError && !unauthorized) {
    content = <VideosFailed retryIn={retryIn} onRetry={() => void videos.refetch()} />;
  } else {
    content = <GridSkeleton />;
  }

  return (
    <div className="flex h-full flex-col overflow-y-auto md:items-center md:gap-7 md:px-14 md:py-10">
      <ProfileHeader
        userId={profile.userId}
        handle={profile.handle}
        displayName={name}
        following={follow.following}
        followDisabled={follow.pending || locked}
        onToggleFollow={follow.toggle}
        onCopyLink={copyLink}
        onBack={back}
      />
      <div
        className={
          tiles.length === 0 && videos.data ? "flex flex-1 flex-col border-t border-border md:border-0" : "contents"
        }
      >
        {content}
      </div>
      <ToastRegion label={t("toast.region")} className="bottom-20 md:bottom-4">
        {toast && (
          <Toast key={toast.id} tone={toast.tone} icon={toast.tone === "success" ? Link2 : undefined}>
            {toast.message}
          </Toast>
        )}
      </ToastRegion>
    </div>
  );
}
