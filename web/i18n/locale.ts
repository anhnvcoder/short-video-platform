import { defaultLocale, isLocale, type Locale } from "./config";

// Picks the locale of a request: the svp_locale cookie when it names a supported locale, else the first supported
// language of Accept-Language by weight, else Vietnamese. The URL carries no locale, so a shared link is the same in
// every language.
export function resolveLocale(cookie: string | undefined, acceptLanguage: string | null): Locale {
  if (isLocale(cookie)) {
    return cookie;
  }
  return fromAcceptLanguage(acceptLanguage ?? "") ?? defaultLocale;
}

function fromAcceptLanguage(header: string): Locale | undefined {
  const ranges: { language: string; weight: number; position: number }[] = [];
  header.split(",").forEach((part, position) => {
    const [range = "", ...params] = part.trim().split(";");
    let weight = 1;
    for (const param of params) {
      const [key, value] = param.trim().split("=");
      if (key?.trim().toLowerCase() === "q") {
        weight = Number(value?.trim());
      }
    }
    // A malformed weight drops the range rather than guessing; q=0 means "not this language".
    if (!Number.isFinite(weight) || weight <= 0 || weight > 1) {
      return;
    }
    // Only the primary subtag matters: vi-VN is vi, en-GB is en.
    ranges.push({ language: range.trim().split("-")[0]?.toLowerCase() ?? "", weight, position });
  });
  ranges.sort((a, b) => b.weight - a.weight || a.position - b.position);
  return ranges.map((range) => range.language).find(isLocale);
}
