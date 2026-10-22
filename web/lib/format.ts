// Short counts for likes and views, as the design writes them: "956", "12,4 N", "3,4 Tr", "1,1 Tỷ" in Vietnamese,
// "12.4K" in English. One decimal at most, cut rather than rounded, so 999 999 reads "999,9 N" and never "1 Tr" before
// it is one. `long` spells the unit out for screen readers ("12,4 nghìn").
export function formatCompact(value: number, locale: string, display: "short" | "long" = "short"): string {
  const parts = new Intl.NumberFormat(locale, {
    notation: "compact",
    compactDisplay: display,
    maximumFractionDigits: 1,
    roundingMode: "trunc",
  }).formatToParts(value);
  return parts
    .map((part) =>
      // CLDR abbreviates billions in Vietnamese as "T", which readers take for "triệu" (million); the design writes "Tỷ".
      part.type === "compact" && part.value === "T" && new Intl.Locale(locale).language === "vi" ? "Tỷ" : part.value,
    )
    .join("");
}

const minuteMs = 60_000;
const hourMs = 60 * minuteMs;
const dayMs = 24 * hourMs;

// How long ago a video was published, as the feed writes it beside the author ("5 phút trước", "3 hours ago"): under a
// minute `justNow` (the caller's translated "vừa xong"), then minutes, hours and days, and from 7 days on the date
// ("21 thg 10", "Oct 21", with the year when it is not this year's). A time slightly ahead of `now` (clocks of two
// machines) also reads `justNow`. `now` is passed in, so the server render, hydration and tests agree on it; `timeZone`
// fixes which calendar day a date falls on. Null when `value` is not a date.
export function formatRelativeTime(
  value: string,
  now: number,
  locale: string,
  timeZone: string,
  justNow: string,
): string | null {
  const time = Date.parse(value);
  if (Number.isNaN(time)) {
    return null;
  }
  const elapsed = now - time;
  if (elapsed < minuteMs) {
    return justNow;
  }
  // "always": "1 ngày trước" rather than "Hôm qua", so every age reads the same way.
  const relative = new Intl.RelativeTimeFormat(locale, { numeric: "always" });
  if (elapsed < hourMs) {
    return relative.format(-Math.floor(elapsed / minuteMs), "minute");
  }
  if (elapsed < dayMs) {
    return relative.format(-Math.floor(elapsed / hourMs), "hour");
  }
  if (elapsed < 7 * dayMs) {
    return relative.format(-Math.floor(elapsed / dayMs), "day");
  }
  const yearOf = (ms: number) => new Intl.DateTimeFormat("en", { year: "numeric", timeZone }).format(ms);
  return new Intl.DateTimeFormat(locale, {
    day: "numeric",
    month: "short",
    year: yearOf(time) === yearOf(now) ? undefined : "numeric",
    timeZone,
  }).format(time);
}
