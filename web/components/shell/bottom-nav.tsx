"use client";

import { House, LogOut } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { LogoutForm } from "./logout-form";
import { isHomePath } from "./nav";

const item = cn(
  "flex min-h-11 w-full flex-col items-center justify-center gap-1 text-[11px] leading-none transition-colors duration-120 ease-out hover:text-foreground",
  focusRing,
);

// Bottom navigation of small screens (web/design/BottomNav.dc.html). Part A has only Home: Upload and Profile come
// with their routes. Log out sits here because the profile screen that holds it in the design does not exist yet.
export function BottomNav() {
  const t = useTranslations("shell");
  const current = isHomePath(usePathname());
  return (
    <nav
      aria-label={t("navLabel")}
      className="grid h-16 shrink-0 grid-cols-2 border-t border-border bg-surface md:hidden"
    >
      <Link
        href="/"
        aria-current={current ? "page" : undefined}
        // The current item is bold as well as brighter, so it does not rely on color alone.
        className={cn(item, current ? "font-bold text-foreground" : "font-medium text-muted")}
      >
        <House aria-hidden="true" size={24} />
        <span>{t("home")}</span>
      </Link>
      <LogoutForm className="flex">
        <button type="submit" className={cn(item, "font-medium text-muted")}>
          <LogOut aria-hidden="true" size={24} />
          <span>{t("logout")}</span>
        </button>
      </LogoutForm>
    </nav>
  );
}
