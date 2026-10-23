"use client";

import { useEffect } from "react";
import { watchVitals } from "./beacon";

// Measures the page's web vitals and sends them to /rum (beacon.ts). web-vitals is loaded only after the page's load
// event, in a chunk of its own, so it takes nothing from the page's first paint; its observers read the entries the
// browser buffered before. Rendered by the root layout: global-error, which replaces that layout, unmounts it, and the
// error page sends nothing. Under app/error.tsx and nested error boundaries the root layout stays mounted, so the
// reporter keeps running and still sends: those values measure the page as it loaded and ran before the error, which
// is real data, not a broken reading of the error page.
export function VitalsReporter() {
  useEffect(() => {
    // The page the visit loaded, before any client-side navigation (beacon.ts).
    const path = location.pathname;
    let cancelled = false;
    let stop: (() => void) | undefined;
    const start = () => {
      import("web-vitals").then(
        (webVitals) => {
          if (!cancelled) {
            stop = watchVitals(webVitals, path);
          }
        },
        () => {},
      );
    };
    if (document.readyState === "complete") {
      start();
    } else {
      addEventListener("load", start, { once: true });
    }
    return () => {
      cancelled = true;
      removeEventListener("load", start);
      stop?.();
    };
  }, []);
  return null;
}
