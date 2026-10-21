"use client";

import { useRef, type KeyboardEvent, type ReactNode } from "react";
import { cn } from "@/lib/cn";
import { focusRing } from "./styles";

export type TabItem = { value: string; label: ReactNode };

const tones = {
  surface: { selected: "text-foreground", other: "text-muted hover:text-foreground" },
  // Over video: white labels with a shadow, in both themes.
  media: { selected: "text-on-media text-shadow-media", other: "text-on-media-muted text-shadow-media" },
} as const;

type TabsProps = {
  // Accessible name of the tab list ("Chọn feed").
  label: string;
  items: TabItem[];
  value: string;
  onChange: (value: string) => void;
  // Prefix of the tab and panel ids; the panel of a tab is rendered by the caller with TabPanel and the same prefix.
  idBase: string;
  tone?: keyof typeof tones;
};

export function tabId(idBase: string, value: string): string {
  return `${idBase}-tab-${value}`;
}

export function tabPanelId(idBase: string, value: string): string {
  return `${idBase}-panel-${value}`;
}

// WAI-ARIA tabs with automatic activation: arrow keys, Home and End move the focus and select the tab; only the
// selected tab is in the Tab order.
export function Tabs({ label, items, value, onChange, idBase, tone = "surface" }: TabsProps) {
  const refs = useRef<(HTMLButtonElement | null)[]>([]);

  function onKeyDown(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    const last = items.length - 1;
    const next =
      event.key === "ArrowRight"
        ? index === last
          ? 0
          : index + 1
        : event.key === "ArrowLeft"
          ? index === 0
            ? last
            : index - 1
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? last
              : undefined;
    const item = next === undefined ? undefined : items[next];
    if (next === undefined || !item) {
      return;
    }
    event.preventDefault();
    refs.current[next]?.focus();
    onChange(item.value);
  }

  return (
    <div role="tablist" aria-label={label} className="flex gap-1">
      {items.map((item, index) => {
        const selected = item.value === value;
        return (
          <button
            key={item.value}
            ref={(element) => {
              refs.current[index] = element;
            }}
            type="button"
            role="tab"
            id={tabId(idBase, item.value)}
            aria-selected={selected}
            aria-controls={tabPanelId(idBase, item.value)}
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(item.value)}
            onKeyDown={(event) => onKeyDown(event, index)}
            className={cn(
              "flex min-h-11 flex-col items-center justify-center gap-1.25 rounded-sm px-3 text-base leading-none transition-colors duration-120 ease-out",
              focusRing,
              selected ? cn("font-bold", tones[tone].selected) : cn("font-medium", tones[tone].other),
            )}
          >
            {item.label}
            <span
              aria-hidden="true"
              className={cn("h-0.5 w-6 rounded-full", selected ? "bg-current" : "bg-transparent")}
            />
          </button>
        );
      })}
    </div>
  );
}

type TabPanelProps = {
  idBase: string;
  value: string;
  children: ReactNode;
  className?: string;
};

export function TabPanel({ idBase, value, children, className }: TabPanelProps) {
  return (
    <div role="tabpanel" id={tabPanelId(idBase, value)} aria-labelledby={tabId(idBase, value)} className={className}>
      {children}
    </div>
  );
}
