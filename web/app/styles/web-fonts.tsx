"use client";

import { useEffect } from "react";
import { beVietnamPro, beVietnamProWeights } from "./fonts";

// The attribute on <html> that switches text from the size-adjusted fallback to Be Vietnam Pro (globals.css). Until it
// is set no text uses the web font, so the browser fetches none of its files: on a slow link the page's largest paint
// (the poster) and its scripts do not share the connections with 68 kB of fonts.
export const webFontsAttribute = "data-web-fonts";

// Loads the four weights once the window's load event has fired, then sets the attribute: every text switches in one
// layout, instead of one reflow per weight as each file arrives. A weight that fails to load is switched to as well;
// the browser then tries it again where text uses it, and shows the fallback meanwhile (font-display: swap). Rendered
// by the root layout and by global-error, which replaces that layout with its own <html>.
export function WebFonts() {
  useEffect(() => {
    let cancelled = false;
    const start = () => {
      const loads = beVietnamProWeights.map((weight) =>
        document.fonts.load(`${weight} 1em ${beVietnamPro.style.fontFamily}`),
      );
      void Promise.allSettled(loads).then(() => {
        if (!cancelled) {
          document.documentElement.setAttribute(webFontsAttribute, "");
        }
      });
    };
    if (document.readyState === "complete") {
      start();
    } else {
      addEventListener("load", start, { once: true });
    }
    return () => {
      cancelled = true;
      removeEventListener("load", start);
    };
  }, []);
  return null;
}
