"use client";

import { useLinkStatus } from "next/link";
import { useTranslations } from "next-intl";
import { useEffect, useState, type ReactNode } from "react";
import { Spinner } from "@/components/ui";

// A navigation that ends this soon shows no spinner: it would only flash.
const delayMs = 150;

type LinkPendingProps = {
  size: number;
  // The link's icon, which the spinner replaces; without one the spinner comes where this is placed, after the text.
  children?: ReactNode;
  className?: string;
};

// Inside a <Link>: a spinner while the navigation it started waits for the next page. The feeds render on the server
// with their first page, so the page the user leaves stays on screen until that page is there, up to the gateway's
// timeout; without this nothing would answer the tap meanwhile. The delay is a timer, not a CSS animation, so it holds
// with reduced motion too, where every animation is off.
export function LinkPending({ size, children, className }: LinkPendingProps) {
  const t = useTranslations("common");
  const { pending } = useLinkStatus();
  const [late, setLate] = useState(false);
  useEffect(() => {
    if (!pending) {
      return;
    }
    const timer = setTimeout(() => setLate(true), delayMs);
    return () => {
      clearTimeout(timer);
      setLate(false);
    };
  }, [pending]);
  if (!pending || !late) {
    return children ?? null;
  }
  return <Spinner size={size} label={t("loading")} className={className} />;
}
