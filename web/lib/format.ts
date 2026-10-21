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
