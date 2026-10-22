"use client";

import { Check, CircleAlert, CircleCheck, CirclePlay, CircleX, LoaderCircle, type LucideIcon } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

// Step 3 once the file is up (M30–M32): a timeline uploaded → processed → ready, and what to do next.

export type ProcessingState = "processing" | "ready" | "failed";

type UploadResultProps = {
  state: ProcessingState;
  // "chieu-ho-guom.mp4 · 19,2 MB".
  fileMeta: string;
  // The share page of the video, when ready.
  videoHref: string | null;
  // Back to step 1 for another file.
  onRestart: () => void;
};

type Node = {
  title: string;
  body?: string;
  big?: boolean;
  look: "done" | "pending" | "processing" | "ready" | "failed";
  badge?: { label: string; Icon: LucideIcon };
  line: "solid" | "dashed" | null;
  current?: boolean;
};

const looks = {
  done: { ring: "bg-success-surface text-success", Icon: Check },
  pending: { ring: "border-2 border-dashed border-border-strong text-muted", Icon: CirclePlay },
  processing: { ring: "border-3 border-warning bg-warning-surface text-warning", Icon: LoaderCircle },
  ready: { ring: "border-3 border-success bg-success-surface text-success", Icon: CircleCheck },
  failed: { ring: "border-3 border-danger bg-danger-surface text-danger", Icon: CircleX },
} as const;

const badgeTones = {
  processing: "bg-warning-surface text-warning",
  ready: "bg-success-surface text-success",
  failed: "bg-danger-surface text-danger",
} as const;

const actionLink = cn(
  "flex min-h-13 w-full items-center justify-center rounded-md px-5 text-base leading-none font-semibold",
  focusRing,
);
const primaryLink = cn(
  actionLink,
  "bg-accent text-accent-foreground hover:bg-accent-hover hover:text-accent-foreground",
);
const secondaryLink = cn(
  actionLink,
  "border border-border-strong text-foreground hover:bg-surface-hover hover:text-foreground",
);

export function UploadResult({ state, fileMeta, videoHref, onRestart }: UploadResultProps) {
  const t = useTranslations("upload.result");
  const nodes: Node[] = [
    { title: t("uploaded"), body: fileMeta, look: "done", line: "solid" },
    state === "ready"
      ? { title: t("processed"), look: "done", line: "solid" }
      : {
          title: state === "failed" ? t("failedTitle") : t("processingTitle"),
          body: state === "failed" ? t("failedBody") : t("processingBody"),
          big: true,
          look: state,
          badge:
            state === "failed"
              ? { label: t("failedBadge"), Icon: CircleAlert }
              : { label: t("processingBadge"), Icon: LoaderCircle },
          line: state === "failed" ? "dashed" : "solid",
          current: true,
        },
    state === "ready"
      ? {
          title: t("readyTitle"),
          body: t("readyBody"),
          big: true,
          look: "ready",
          badge: { label: t("readyBadge"), Icon: Check },
          line: null,
          current: true,
        }
      : {
          title: t("readyPending"),
          body: state === "failed" ? undefined : t("readyPendingBody"),
          look: "pending",
          line: null,
        },
  ];

  return (
    <>
      <ol aria-label={t("label")} className="flex flex-1 flex-col pt-2">
        {nodes.map((node) => {
          const { ring, Icon } = looks[node.look];
          const badgeTone = node.look === "done" || node.look === "pending" ? null : badgeTones[node.look];
          return (
            <li
              key={node.title}
              aria-current={node.current ? "step" : undefined}
              className="grid grid-cols-[56px_minmax(0,1fr)] gap-x-4"
            >
              <div className="flex flex-col items-center">
                <span className={cn("flex size-13 flex-none items-center justify-center rounded-full", ring)}>
                  <Icon
                    aria-hidden="true"
                    size={22}
                    className={node.look === "processing" ? "animate-svp-spin" : undefined}
                  />
                </span>
                {node.line && (
                  <span
                    aria-hidden="true"
                    className={cn(
                      "my-1.5 min-h-7 w-0 flex-1 border-l-2 border-border-strong",
                      node.line === "dashed" && "border-dashed",
                    )}
                  />
                )}
              </div>
              <div className="flex flex-col gap-1.5 pt-3 pb-6">
                <div className="flex flex-wrap items-center gap-2.5">
                  <strong
                    className={cn(
                      "leading-tight font-bold",
                      node.big ? "text-[22px]" : "text-base",
                      node.look === "pending" ? "text-muted" : "text-foreground",
                    )}
                  >
                    {node.title}
                  </strong>
                  {node.badge && badgeTone && (
                    <span
                      className={cn(
                        "inline-flex h-6 items-center gap-1.25 rounded-full px-2.25 text-xs font-semibold",
                        badgeTone,
                      )}
                    >
                      <node.badge.Icon aria-hidden="true" size={13} />
                      {node.badge.label}
                    </span>
                  )}
                </div>
                {node.body && (
                  <p className="text-sm leading-normal text-pretty text-muted wrap-anywhere">{node.body}</p>
                )}
              </div>
            </li>
          );
        })}
      </ol>
      <div className="flex flex-col gap-2.5">
        {state === "ready" && videoHref && (
          <Link href={videoHref} className={primaryLink}>
            {t("watch")}
          </Link>
        )}
        {state === "failed" && (
          <Button size="lg" className="w-full" onClick={onRestart}>
            {t("pickAnother")}
          </Button>
        )}
        {state === "ready" ? (
          <Button variant="secondary" size="lg" className="w-full" onClick={onRestart}>
            {t("another")}
          </Button>
        ) : (
          <Link href="/me" className={secondaryLink}>
            {t("myVideos")}
          </Link>
        )}
      </div>
    </>
  );
}
