import { useTranslations } from "next-intl";
import { useEffect, useRef, useState } from "react";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

// The video title in two lines; a tap shows all of it. The title is the uploader's text and is rendered as React text
// only, never as HTML (WEB-1).
export function FeedTitle({ title }: { title: string }) {
  const t = useTranslations("feed");
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const textRef = useRef<HTMLSpanElement>(null);

  // "More" only when two lines do not hold the title; measured again when the width changes.
  useEffect(() => {
    const text = textRef.current;
    if (!text || expanded || typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(() => setOverflows(text.scrollHeight > text.clientHeight + 1));
    observer.observe(text);
    return () => observer.disconnect();
  }, [title, expanded]);

  if (!title) {
    return null;
  }
  const toggles = overflows || expanded;
  return (
    <button
      type="button"
      aria-expanded={toggles ? expanded : undefined}
      disabled={!toggles}
      onClick={() => setExpanded((value) => !value)}
      className={cn(
        "flex flex-col gap-0.5 rounded-sm text-left text-[15px] leading-[1.45] text-on-media text-shadow-media disabled:cursor-auto",
        focusRing,
      )}
    >
      <span ref={textRef} className={cn("break-words", !expanded && "line-clamp-2")}>
        {title}
      </span>
      {toggles && (
        <span className="font-semibold text-on-media-muted">{expanded ? t("titleLess") : t("titleMore")}</span>
      )}
    </button>
  );
}
