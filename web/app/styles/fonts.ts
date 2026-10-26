import localFont from "next/font/local";

// Be Vietnam Pro (SIL Open Font License, ./fonts/OFL.txt), self-hosted so the page loads fonts from its own origin only
// (CSP font-src 'self') and `next build` needs no network. One woff2 per weight the design uses, each subset to Basic
// Latin, Latin-1, the Vietnamese letters and tone marks, and common punctuation (Google Fonts `text=` subsetting).
export const beVietnamPro = localFont({
  src: [
    { path: "./fonts/be-vietnam-pro-400.woff2", weight: "400", style: "normal" },
    { path: "./fonts/be-vietnam-pro-500.woff2", weight: "500", style: "normal" },
    { path: "./fonts/be-vietnam-pro-600.woff2", weight: "600", style: "normal" },
    { path: "./fonts/be-vietnam-pro-700.woff2", weight: "700", style: "normal" },
  ],
  variable: "--font-be-vietnam-pro",
  display: "swap",
  // No <link rel="preload"> for the four files: text paints in the size-adjusted fallback until the page has loaded,
  // and only then are the fonts fetched and switched to (web-fonts.tsx), so 68 kB of fonts never compete with the
  // poster, the page's largest paint, or with the page's scripts on a slow link.
  preload: false,
});

// The weights of `src` above (next/font takes only literal options, so the list cannot be built from this one).
export const beVietnamProWeights = ["400", "500", "600", "700"] as const;
