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

// Texts the server wrote for "5 minutes ago", by published_at, counted from the time it rendered the page.
export type RenderedAgo = { at: number; texts: Readonly<Record<string, string | null>> };

// "2 ngày trước" for a video's published_at, in the page's locale, counted from `now`. While `now` is still the time
// in `rendered`, the server's text is read back instead of formatted again, so hydration builds no
// Intl.RelativeTimeFormat: a page's first one costs tens of milliseconds of ICU setup, all of it inside the hydration
// task. Once the clock moves on, or for a video the server did not render, the browser formats it.
export function usePublishedAgo(now: number, rendered?: RenderedAgo): (publishedAt: string) => string | null {
  const t = useTranslations("feed");
  const locale = useLocale();
  const justNow = t("justNow");
  return (publishedAt) => {
    if (rendered?.at === now && Object.hasOwn(rendered.texts, publishedAt)) {
      return rendered.texts[publishedAt] ?? null;
    }
    return formatRelativeTime(publishedAt, now, locale, timeZone, justNow);
  };
}
