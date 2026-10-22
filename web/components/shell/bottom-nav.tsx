"use client";

import { House, Plus, User } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { currentNavItem } from "./nav";

const item = cn(
  "flex min-h-11 w-full flex-col items-center justify-center gap-1 text-[11px] leading-none transition-colors duration-120 ease-out hover:text-foreground",
  focusRing,
);

// The current item is bold as well as brighter, so it does not rely on color alone.
function itemState(current: boolean): string {
  return current ? "font-bold text-foreground" : "font-medium text-muted";
}

// Bottom navigation of small screens (web/design/BottomNav.dc.html): Home, Upload, Profile. Log out is on the profile
// page (/me), as in the design.
export function BottomNav() {
  const t = useTranslations("shell");
  const current = currentNavItem(usePathname());
  return (
    <nav
      aria-label={t("navLabel")}
      className="grid h-16 shrink-0 grid-cols-3 border-t border-border bg-surface md:hidden"
    >
      <Link
        href="/"
        aria-current={current === "home" ? "page" : undefined}
        className={cn(item, itemState(current === "home"))}
      >
        <House aria-hidden="true" size={24} />
        <span>{t("home")}</span>
      </Link>
      <Link
        href="/upload"
        aria-current={current === "upload" ? "page" : undefined}
        className={cn(item, itemState(current === "upload"))}
      >
        <span className="flex h-8 w-13 items-center justify-center rounded-[10px] bg-accent text-accent-foreground">
          <Plus aria-hidden="true" size={22} />
        </span>
        <span>{t("upload")}</span>
      </Link>
      <Link
        href="/me"
        aria-current={current === "profile" ? "page" : undefined}
        className={cn(item, itemState(current === "profile"))}
      >
        <User aria-hidden="true" size={24} />
        <span>{t("profile")}</span>
      </Link>
    </nav>
  );
}
