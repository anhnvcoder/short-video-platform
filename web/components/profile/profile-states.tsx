import { Film, Plus, RotateCw, UserX, type LucideIcon } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { primaryAction } from "@/components/shell/error-screen";
import { Button, Skeleton } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

// The profile pages' states without a video (web/design/SVP Mobile.dc.html M37): loading, empty, a page that failed,
// and the profile 404.

function Message({
  icon: Icon,
  title,
  body,
  heading = "strong",
  children,
}: {
  icon: LucideIcon;
  title: string;
  body: string;
  heading?: "strong" | "h1";
  children?: ReactNode;
}) {
  const Title = heading;
  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-3 p-8 text-center">
      <Icon aria-hidden="true" size={36} className="text-muted" />
      <Title className="text-[17px] font-semibold">{title}</Title>
      <p className="max-w-65 text-[15px] leading-normal text-pretty text-muted">{body}</p>
      {children}
    </div>
  );
}

export function EmptyMyVideos() {
  const t = useTranslations("profile.my.empty");
  return (
    <Message icon={Film} title={t("title")} body={t("body")}>
      <Link href="/upload" className={cn(primaryAction, "mt-2", focusRing)}>
        <Plus aria-hidden="true" size={18} />
        {t("action")}
      </Link>
    </Message>
  );
}

// M37. `name` is the user's own text, passed into the translated sentence as a value (React escapes it).
export function EmptyProfileVideos({ name }: { name: string }) {
  const t = useTranslations("profile.other.empty");
  return <Message icon={Film} title={t("title")} body={t("body", { name })} />;
}

// A page of videos that could not be had; `retryIn` counts down a rate limit first.
export function VideosFailed({ retryIn, onRetry }: { retryIn: number; onRetry: () => void }) {
  const t = useTranslations("profile");
  return (
    <div role="alert" className="flex flex-col items-center gap-3 p-6 text-center text-[15px] text-muted">
      {t("loadFailed")}
      <Button variant="secondary" disabled={retryIn > 0} onClick={onRetry} className="tabular-nums">
        <RotateCw aria-hidden="true" size={18} />
        {retryIn > 0 ? t("retryIn", { seconds: retryIn }) : t("retry")}
      </Button>
    </div>
  );
}

export function ListSkeleton() {
  const t = useTranslations("profile");
  return (
    <div role="status" aria-busy="true" aria-label={t("loadingVideos")} className="flex flex-col px-4 md:px-0">
      {[0, 1, 2].map((row) => (
        <div key={row} className="flex gap-3.5 border-b border-border py-3">
          <Skeleton className="h-28.5 w-16 rounded-[10px] md:h-25 md:w-14" />
          <div className="flex flex-1 flex-col gap-2.5 pt-1">
            <Skeleton className="h-3.5 w-4/5 rounded-md" />
            <Skeleton className="h-6 w-24 rounded-full" />
          </div>
        </div>
      ))}
    </div>
  );
}

export function GridSkeleton() {
  const t = useTranslations("profile");
  return (
    <div
      role="status"
      aria-busy="true"
      aria-label={t("loadingVideos")}
      className="grid w-full grid-cols-3 gap-0.5 md:max-w-240 md:grid-cols-6 md:gap-2"
    >
      {[0, 1, 2, 3, 4, 5].map((tile) => (
        <Skeleton key={tile} className="aspect-9/16 rounded-none md:rounded-[10px]" />
      ))}
    </div>
  );
}

// The 404 of /u/<handle>: no user has the handle, or it cannot be one. Inside the app's frame, so the navigation stays.
export function ProfileNotFound() {
  const t = useTranslations("profile.notFound");
  return (
    <Message icon={UserX} heading="h1" title={t("title")} body={t("body")}>
      <Link href="/" className={cn(primaryAction, "mt-2", focusRing)}>
        {t("home")}
      </Link>
    </Message>
  );
}
