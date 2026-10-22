"use client";

import { RotateCw, X } from "lucide-react";
import { useTranslations } from "next-intl";
import { useLayoutEffect, useRef, type ReactNode } from "react";
import { Button } from "@/components/ui";
import { cn } from "@/lib/cn";

// Step 3 while the file goes up (M28, M29): percentage, bar, sizes and speed, the file, and cancel. On a failure that
// can be resumed it also offers "Retry".

type UploadProgressProps = {
  // The line above the bar: "Uploading (64%)", "Waiting for a connection", "Finishing".
  heading: string;
  // 0 to 1.
  progress: number;
  // The bar is grey while nothing is sent.
  paused: boolean;
  // "12,3 / 19,2 MB · 2,1 MB/s · about 4 seconds left".
  meta: string;
  videoTitle: string;
  // "chieu-ho-guom.mp4 · 19,2 MB".
  fileMeta: string;
  alert?: ReactNode;
  onCancel: () => void;
  // Shown when the upload stopped on a failure it can resume from.
  onRetry?: () => void;
};

export function UploadProgress({
  heading,
  progress,
  paused,
  meta,
  videoTitle,
  fileMeta,
  alert,
  onCancel,
  onRetry,
}: UploadProgressProps) {
  const t = useTranslations("upload.progress");
  const bar = useRef<HTMLDivElement>(null);
  const percent = Math.round(progress * 100);

  // Set through the DOM rather than a style attribute, which the CSP does not allow in server-rendered HTML.
  useLayoutEffect(() => {
    if (bar.current) {
      bar.current.style.width = `${progress * 100}%`;
    }
  }, [progress]);

  return (
    <>
      {alert}
      <div className="flex flex-col gap-2.5">
        <span className="text-[15px] font-semibold tabular-nums">{heading}</span>
        <div
          role="progressbar"
          aria-label={t("label")}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={percent}
          className="h-1.5 overflow-hidden rounded-[6px] bg-skeleton"
        >
          <div
            ref={bar}
            className={cn(
              "h-full w-0 rounded-[6px] transition-[width] duration-200",
              paused ? "bg-muted" : "bg-accent",
            )}
          />
        </div>
        <span className="text-[13px] text-muted tabular-nums">{meta}</span>
      </div>
      <div className="flex flex-col gap-1 rounded-lg border border-border bg-surface-raised p-4">
        <strong className="line-clamp-2 text-[15px] leading-[1.4] font-semibold wrap-anywhere">{videoTitle}</strong>
        <span className="text-[13px] text-muted wrap-anywhere">{fileMeta}</span>
      </div>
      <p className="text-sm leading-normal text-pretty text-muted">{t("keepOpen")}</p>
      <div className="mt-auto flex flex-col gap-2.5">
        {onRetry && (
          <Button size="lg" className="w-full" onClick={onRetry}>
            <RotateCw aria-hidden="true" size={18} />
            {t("retry")}
          </Button>
        )}
        <Button variant="secondary" size="lg" className="w-full" onClick={onCancel}>
          <X aria-hidden="true" size={18} />
          {t("cancel")}
        </Button>
        <p className="text-center text-[13px] leading-normal text-muted">{t("cancelNote")}</p>
      </div>
    </>
  );
}
