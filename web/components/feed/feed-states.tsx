import { CircleAlert, CircleCheck, Compass, RotateCcw, RotateCw, Users, WifiOff, type LucideIcon } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { Button, Skeleton } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

// The feed's screens without a video (web/design/FeedMobile.dc.html: loading, empty-following, end, offline).

function Message({
  icon: Icon,
  title,
  body,
  children,
}: {
  icon: LucideIcon;
  title: string;
  body: string;
  children?: ReactNode;
}) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-4 p-8 text-center text-foreground">
      <span className="flex size-18 items-center justify-center rounded-full bg-surface-raised">
        <Icon aria-hidden="true" size={30} className="text-muted" />
      </span>
      <h2 className="text-xl font-bold">{title}</h2>
      <p className="max-w-70 text-[15px] leading-normal text-pretty text-muted">{body}</p>
      {children}
    </div>
  );
}

// First page still loading: the shapes of the actions and the title over a dark stage. A status, so the label is
// allowed on it (a plain div may not carry one).
export function FeedSkeleton() {
  const t = useTranslations("feed");
  return (
    <div
      role="status"
      aria-busy="true"
      aria-label={t("loading")}
      className="relative h-full bg-[oklch(0_0_0)] md:bg-surface"
    >
      <div className="absolute right-3 bottom-7 flex flex-col items-center gap-5.5">
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
  );
}

export function EmptyFeed({ kind }: { kind: "explore" | "following" }) {
  const t = useTranslations("feed.empty");
  if (kind === "explore") {
    return <Message icon={Users} title={t("exploreTitle")} body={t("exploreBody")} />;
  }
  return (
    <Message icon={Users} title={t("followingTitle")} body={t("followingBody")}>
      <Link
        href="/"
        className={cn(
          "mt-2 flex min-h-12 items-center gap-2 rounded-md bg-accent px-6 text-[15px] leading-none font-semibold text-accent-foreground hover:bg-accent-hover hover:text-accent-foreground",
          focusRing,
        )}
      >
        <Compass aria-hidden="true" size={18} />
        {t("followingAction")}
      </Link>
    </Message>
  );
}

// After the last video, once the feed has no more pages.
export function FeedEnd({ kind, onRestart }: { kind: "explore" | "following"; onRestart: () => void }) {
  const t = useTranslations("feed.end");
  return (
    <Message icon={CircleCheck} title={t("title")} body={kind === "explore" ? t("exploreBody") : t("followingBody")}>
      <Button variant="secondary" size="lg" onClick={onRestart} className="mt-2 px-6">
        <RotateCcw aria-hidden="true" size={18} />
        {t("action")}
      </Button>
    </Message>
  );
}

// A page of the feed failed after its retries: the first page fills the screen, a later one the item after the last
// video. `locked` holds the retry while the Retry-After of a 429 runs.
export function FeedLoadError({
  rateLimited,
  locked,
  onRetry,
}: {
  rateLimited: boolean;
  locked: boolean;
  onRetry: () => void;
}) {
  const t = useTranslations("feed.loadError");
  return (
    <div role="alert" className="h-full bg-surface">
      <Message icon={CircleAlert} title={t("title")} body={rateLimited ? t("rateLimited") : t("body")}>
        <Button variant="secondary" size="lg" disabled={locked} onClick={onRetry} className="mt-2 px-6">
          <RotateCw aria-hidden="true" size={18} />
          {t("retry")}
        </Button>
      </Message>
    </div>
  );
}

export function OfflineBanner() {
  const t = useTranslations("feed.offline");
  return (
    <div
      role="status"
      className="absolute inset-x-3 top-15 z-30 flex items-center gap-3 rounded-md border border-border bg-surface-raised px-3.5 py-3 text-foreground md:top-19 md:right-auto md:left-1/2 md:w-100 md:-translate-x-1/2"
    >
      <WifiOff aria-hidden="true" size={20} className="shrink-0 text-warning" />
      <div className="flex flex-col gap-0.5 text-sm leading-[1.35]">
        <strong className="font-semibold">{t("title")}</strong>
        <span className="text-muted">{t("body")}</span>
      </div>
    </div>
  );
}
