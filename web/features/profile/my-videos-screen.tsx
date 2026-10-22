"use client";

import { useRouter } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
import { useEffect, useEffectEvent, useMemo, type ReactNode } from "react";
import { MyVideoRow, type RowProgress } from "@/components/profile/my-video-row";
import { EmptyMyVideos, ListSkeleton, VideosFailed } from "@/components/profile/profile-states";
import { useCountdown } from "@/components/shell/use-countdown";
import { Button } from "@/components/ui";
import { ApiError, loginHref } from "@/features/feed/api";
import { isMediaUrl } from "@/features/feed/media-url";
import { useNow } from "@/features/feed/use-now";
import { formatDuration, formatMegabytes } from "@/features/upload/format";
import { useUploads, type Upload, type UploadStore } from "@/features/upload/upload-store";
import { timeZone } from "@/i18n/config";
import { formatCompact, formatRelativeTime } from "@/lib/format";
import type { ProfileVideo, ProfileVideoPage, VideoStatus } from "./api";
import { useVideoPages } from "./use-video-pages";

type MyVideosScreenProps = {
  // The logged-in user.
  userId: string;
  initialPage: ProfileVideoPage | undefined;
  // Set when the server's request got 429 and no page: the first request waits this long.
  initialRetryAfterSeconds?: number;
  // MEDIA_ORIGIN of the server: thumbnails are shown only from there.
  mediaOrigin: string;
  // When the server rendered the page (ms since the epoch): the clock of "3 days ago" until the browser's takes over.
  renderedAt: number;
  // The uploads of this tab; the app's store unless a test passes its own.
  uploadStore?: UploadStore;
};

// Uploads still sending their file: their row shows the progress.
const sendingStatuses: ReadonlySet<Upload["status"]> = new Set(["preparing", "sending", "waiting", "completing"]);

type Row = {
  key: string;
  title: string;
  status: VideoStatus;
  video: ProfileVideo | null;
  upload: Upload | null;
};

// The uploads of this tab whose video the list does not hold yet (just created, or not on the pages loaded) come first,
// newest first, like the list; every other upload is matched to its row by video id.
function rowsOf(videos: readonly ProfileVideo[], uploads: readonly Upload[]): Row[] {
  const listed = new Set(videos.map((video) => video.video_id));
  const byVideo = new Map(uploads.filter((upload) => upload.videoId).map((upload) => [upload.videoId, upload]));
  const unlisted = [...uploads]
    .reverse()
    .filter(
      (upload) =>
        (sendingStatuses.has(upload.status) || upload.status === "processing") &&
        !(upload.videoId && listed.has(upload.videoId)),
    );
  return [
    ...unlisted.map((upload) => ({
      key: upload.key,
      title: upload.title,
      status: (upload.status === "processing" ? "PROCESSING" : "UPLOADING") as VideoStatus,
      video: null,
      upload,
    })),
    ...videos.map((video) => ({
      key: video.video_id,
      title: video.title,
      status: video.status,
      video,
      upload: byVideo.get(video.video_id) ?? null,
    })),
  ];
}

// Video ids of the uploads the list should show: the server has created them, and they are not cancelled or failed.
function awaitedIdsOf(uploads: readonly Upload[]): string[] {
  return uploads.flatMap((upload) =>
    upload.videoId && (sendingStatuses.has(upload.status) || upload.status === "processing") ? [upload.videoId] : [],
  );
}

// "My videos" (/me; web/design/SVP Mobile.dc.html M33–M34, SVP Desktop.dc.html D09): every video of the user in every
// state, newest first, with the progress of the uploads running in this tab. The list asks again while a video is
// unfinished (use-video-pages.ts).
export function MyVideosScreen({
  userId,
  initialPage,
  initialRetryAfterSeconds,
  mediaOrigin,
  renderedAt,
  uploadStore,
}: MyVideosScreenProps) {
  const t = useTranslations("profile");
  const locale = useLocale();
  const router = useRouter();
  const now = useNow(renderedAt);
  const uploads = useUploads(uploadStore);
  // Read from a deadline like the login page's countdown, so a page in the background never asks early.
  const firstWait = useCountdown(initialPage ? null : (initialRetryAfterSeconds ?? null), userId);

  const videos = useVideoPages({
    list: "mine",
    userId,
    initialPage,
    enabled: firstWait === 0,
    awaitedIds: awaitedIdsOf(uploads),
  });
  const items = useMemo(() => {
    // A page asked again can repeat a video of the next page; one row per video.
    const seen = new Set<string>();
    return (videos.data?.pages.flatMap((page) => page.items) ?? []).filter((video) =>
      seen.has(video.video_id) ? false : (seen.add(video.video_id), true),
    );
  }, [videos.data]);
  const rows = rowsOf(items, uploads);

  const loadError = videos.error instanceof ApiError ? videos.error : null;
  const retryIn = useCountdown(loadError?.status === 429 ? (loadError.retryAfterSeconds ?? 1) : null, videos.error);
  const unauthorized = loadError?.status === 401;
  const redirectToLogin = useEffectEvent(() => router.replace(loginHref("/me")));
  useEffect(() => {
    if (unauthorized) {
      redirectToLogin();
    }
  }, [unauthorized]);

  function progressOf(upload: Upload | null): RowProgress | null {
    if (!upload || !sendingStatuses.has(upload.status)) {
      return null;
    }
    const percent = t("progress.percent", { percent: Math.round(upload.progress * 100) });
    const detail =
      upload.status === "preparing"
        ? t("progress.preparing")
        : upload.status === "waiting"
          ? t("progress.waiting")
          : upload.status === "completing"
            ? t("progress.completing")
            : upload.bytesPerSecond === null
              ? percent
              : `${percent} · ${t("progress.speed", { speed: formatMegabytes(upload.bytesPerSecond, locale) })}`;
    return { value: upload.progress, detail };
  }

  function rowProps(row: Row) {
    const { video } = row;
    const ready = video?.status === "READY";
    return {
      title: row.title,
      status: row.status,
      href: ready ? `/v/${video.video_id}` : null,
      thumbnailUrl:
        ready && video.thumbnail_url && isMediaUrl(video.thumbnail_url, mediaOrigin) ? video.thumbnail_url : null,
      duration: ready && video.duration_ms !== undefined ? formatDuration(video.duration_ms / 1000) : null,
      views:
        ready && video.view_count !== undefined
          ? t("viewCount", { count: formatCompact(video.view_count, locale) })
          : null,
      publishedAgo:
        ready && video.published_at
          ? formatRelativeTime(video.published_at, now, locale, timeZone, t("justNow"))
          : null,
      progress: progressOf(row.upload),
    };
  }

  let list: ReactNode;
  if (rows.length > 0) {
    list = (
      <>
        <div
          aria-hidden="true"
          className="hidden grid-cols-[56px_minmax(0,1fr)_140px_90px_110px_110px] gap-5 border-b border-border pb-2.5 text-[13px] font-semibold text-muted md:grid"
        >
          <span />
          <span>{t("my.columns.video")}</span>
          <span>{t("my.columns.status")}</span>
          <span>{t("my.columns.duration")}</span>
          <span>{t("my.columns.views")}</span>
          <span>{t("my.columns.published")}</span>
        </div>
        <ul aria-label={t("my.listLabel")} className="flex flex-col">
          {rows.map((row) => (
            <MyVideoRow key={row.key} {...rowProps(row)} />
          ))}
        </ul>
        {videos.isFetchNextPageError ? (
          <VideosFailed retryIn={retryIn} onRetry={() => void videos.fetchNextPage()} />
        ) : (
          videos.hasNextPage && (
            <Button
              variant="secondary"
              loading={videos.isFetchingNextPage}
              onClick={() => void videos.fetchNextPage()}
              className="mt-4 self-center"
            >
              {t("loadMore")}
            </Button>
          )
        )}
      </>
    );
  } else if (videos.data) {
    list = <EmptyMyVideos />;
  } else if (videos.isError && !unauthorized) {
    list = <VideosFailed retryIn={retryIn} onRetry={() => void videos.refetch()} />;
  } else {
    list = <ListSkeleton />;
  }

  return <section className="flex flex-col px-4 md:px-0">{list}</section>;
}
