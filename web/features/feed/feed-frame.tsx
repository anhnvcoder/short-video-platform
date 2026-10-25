"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { Tabs, TabPanel } from "@/components/ui";
import type { FeedKind } from "./api";

type FeedFrameProps = {
  // The selected tab: the page's, or the one the user switched to while its page loads.
  kind: FeedKind;
  onSelect: (kind: FeedKind) => void;
  // The tab's panel: the feed, with the skeleton laid over it while the other tab loads.
  children: ReactNode;
  // Laid over the frame: the offline banner, the desktop arrows, the toasts.
  overlays?: ReactNode;
};

// The frame of both feed pages: the Explore / Following tabs over the video on small screens and above it on wide
// ones, and the selected tab's panel.
export function FeedFrame({ kind, onSelect, children, overlays }: FeedFrameProps) {
  const t = useTranslations("feed");
  return (
    <div className="relative flex h-full flex-col bg-[oklch(0_0_0)] md:bg-surface">
      {/* Over the video on small screens, above it on wide ones; only the tabs take taps. */}
      <header className="pointer-events-none absolute inset-x-0 top-0 z-20 flex h-14 items-center justify-center md:static md:h-17 md:shrink-0">
        <div className="pointer-events-auto">
          <Tabs
            label={t("tabs.label")}
            idBase="feed"
            tone="media"
            value={kind}
            items={[
              { value: "following", label: t("tabs.following") },
              { value: "explore", label: t("tabs.explore") },
            ]}
            onChange={(value) => onSelect(value === "explore" ? "explore" : "following")}
          />
        </div>
      </header>
      <TabPanel idBase="feed" value={kind} className="relative min-h-0 flex-1">
        {children}
      </TabPanel>
      {overlays}
    </div>
  );
}
