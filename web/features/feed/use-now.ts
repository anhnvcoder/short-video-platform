import { useLocale, useTranslations } from "next-intl";
import { useEffect, useState } from "react";
import { timeZone } from "@/i18n/config";
import { formatRelativeTime } from "@/lib/format";

// The clock the feed counts "5 minutes ago" from. It starts at `initial`, the time the server rendered the page, so
// hydration reads the same text the server wrote, and moves on once a minute.
export function useNow(initial: number, intervalMs = 60_000): number {
  const [now, setNow] = useState(initial);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(timer);
  }, [intervalMs]);
  return now;
}

// "2 ngày trước" for a video's published_at, in the page's locale, counted from `now`.
export function usePublishedAgo(now: number): (publishedAt: string) => string | null {
  const t = useTranslations("feed");
  const locale = useLocale();
  const justNow = t("justNow");
  return (publishedAt) => formatRelativeTime(publishedAt, now, locale, timeZone, justNow);
}
