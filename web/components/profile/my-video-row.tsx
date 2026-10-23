"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { useLayoutEffect, useRef } from "react";
import { focusRing } from "@/components/ui/styles";
import type { VideoStatus } from "@/features/profile/api";
import { cn } from "@/lib/cn";
import { StatusBadge } from "./status-badge";

export type RowProgress = {
  // 0 to 1.
  value: number;
  // "64% · 2,1 MB/s", "Đang chờ kết nối".
  detail: string;
};

type MyVideoRowProps = {
  // The user's own text, rendered as React text only (WEB-1); empty when the video has none.
  title: string;
  status: VideoStatus;
  // The share page of a READY video.
  href: string | null;
  // On MEDIA_ORIGIN, checked by the caller.
  thumbnailUrl: string | null;
  // "0:58".
  duration: string | null;
  // "8,3 N lượt xem".
  views: string | null;
  // "3 ngày trước".
  publishedAgo: string | null;
  // The upload of this video running in this tab.
  progress: RowProgress | null;
};

// One of the user's videos (web/design/SVP Mobile.dc.html M33–M34; SVP Desktop.dc.html D09): on a phone the details
// stack beside the thumbnail, on a wide screen they sit in the columns of the list's header.
export function MyVideoRow({
  title,
  status,
  href,
  thumbnailUrl,
  duration,
  views,
  publishedAgo,
  progress,
}: MyVideoRowProps) {
  const t = useTranslations("profile");
  const shownTitle = title || t("untitled");
  const meta = [duration, views, publishedAgo].filter((part) => part !== null).join(" · ");
  return (
    <li className="flex gap-3.5 border-b border-border py-3 md:grid md:grid-cols-[56px_minmax(0,1fr)_140px_90px_110px_110px] md:items-center md:gap-5">
      <div
        className={cn(
          "relative h-28.5 w-16 shrink-0 overflow-hidden rounded-[10px] bg-skeleton md:h-25 md:w-14 md:rounded-lg",
          status === "FAILED" && "opacity-50",
        )}
      >
        {thumbnailUrl && (
          // A plain <img>: next/image always writes a style attribute, which the CSP (no 'unsafe-inline') blocks.
          // eslint-disable-next-line @next/next/no-img-element
          <img src={thumbnailUrl} alt="" className="absolute inset-0 size-full object-cover" />
        )}
        {duration && (
          <span className="absolute right-1 bottom-1 rounded-[5px] bg-[oklch(0_0_0/0.65)] px-1.25 font-mono text-[11px] leading-[1.4] font-medium text-on-media md:hidden">
            {duration}
          </span>
        )}
      </div>
      <div className="flex min-w-0 flex-1 flex-col gap-2 pt-0.5 md:gap-1.5 md:pt-0">
        {href ? (
          <Link
            href={href}
            className={cn(
              "line-clamp-2 self-start rounded-sm text-[15px] leading-[1.4] font-medium wrap-anywhere text-foreground hover:underline",
              focusRing,
            )}
          >
            {shownTitle}
          </Link>
        ) : (
          <span className="line-clamp-2 text-[15px] leading-[1.4] font-medium wrap-anywhere">{shownTitle}</span>
        )}
        <StatusBadge status={status} className="md:hidden" />
        {progress && <ProgressLine progress={progress} />}
        {meta && <span className="text-[13px] text-muted md:hidden">{meta}</span>}
        {status === "FAILED" && <FailedLine />}
      </div>
      {/* max-md:hidden rather than "hidden md:inline-flex": Tailwind emits .inline-flex, the badge's own display, after
          .hidden, so a plain hidden would lose and phones would show this badge under the first one. */}
      <StatusBadge status={status} className="max-md:hidden" />
      <span className="hidden font-mono text-[13px] text-muted md:block">{duration}</span>
      <span className="hidden text-sm text-muted md:block">{views}</span>
      <span className="hidden text-sm text-muted md:block">{publishedAgo}</span>
    </li>
  );
}

function ProgressLine({ progress }: { progress: RowProgress }) {
  const t = useTranslations("profile.progress");
  const bar = useRef<HTMLDivElement>(null);
  const percent = Math.round(progress.value * 100);

  // Set through the DOM rather than a style attribute, which the CSP does not allow in server-rendered HTML.
  useLayoutEffect(() => {
    if (bar.current) {
      bar.current.style.width = `${progress.value * 100}%`;
    }
  }, [progress.value]);

  return (
    <div className="flex flex-col gap-1.5 md:max-w-80 md:flex-row md:items-center md:gap-2.5">
      <div
        role="progressbar"
        aria-label={t("label")}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={percent}
        className="h-1 overflow-hidden rounded-sm bg-skeleton md:flex-1"
      >
        <div ref={bar} className="h-full w-0 bg-accent transition-[width] duration-200" />
      </div>
      <span className="text-[13px] text-muted tabular-nums">{progress.detail}</span>
    </div>
  );
}

function FailedLine() {
  const t = useTranslations("profile.my");
  return (
    <span className="flex flex-wrap items-center gap-x-3 text-[13px] text-muted">
      {t("failed")}
      <Link href="/upload" className={cn("rounded-sm py-1.5 font-semibold text-accent-text", focusRing)}>
        {t("reupload")}
      </Link>
    </span>
  );
}
