"use client";

import { House, LogOut } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import { Avatar, IconButton } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { LogoutForm } from "./logout-form";
import { isHomePath } from "./nav";

const kbd =
  "inline-flex h-6 min-w-6 items-center justify-center rounded-[6px] border border-border-strong bg-surface-raised px-1.5 font-mono text-xs font-medium text-foreground";

type SidebarDesktopProps = {
  // Seed of the avatar color; the user has no name or handle yet.
  userId: string;
  appName: string;
};

// Side bar of wide screens (web/design/SidebarDesktop.dc.html). Part A has only Home: Upload and Profile come with
// their routes.
export function SidebarDesktop({ userId, appName }: SidebarDesktopProps) {
  const t = useTranslations("shell");
  const current = isHomePath(usePathname());
  return (
    <aside className="hidden h-full w-62 shrink-0 flex-col gap-1.5 border-r border-border bg-surface px-4 py-5 text-foreground md:flex">
      <Link
        href="/"
        className={cn("rounded-sm px-3 pt-2 pb-5 text-[22px] font-bold tracking-[0.1em] text-foreground", focusRing)}
      >
        {appName}
      </Link>
      <nav aria-label={t("navLabel")} className="flex flex-col gap-1">
        <Link
          href="/"
          aria-current={current ? "page" : undefined}
          // The current item has a background and a heavier weight, so it does not rely on color alone.
          className={cn(
            "flex min-h-12 items-center gap-3.5 rounded-md px-3 text-[15px] transition-colors duration-120 ease-out hover:bg-surface-hover hover:text-foreground",
            focusRing,
            current ? "bg-surface-hover font-semibold text-foreground" : "font-medium text-muted",
          )}
        >
          <House aria-hidden="true" size={22} />
          {t("home")}
        </Link>
      </nav>
      <div className="mt-auto flex flex-col gap-4">
        {current && (
          <section
            aria-labelledby="shortcuts-title"
            className="flex flex-col gap-2.5 rounded-md border border-border p-3.5 text-[13px] text-muted"
          >
            <h2 id="shortcuts-title" className="font-semibold text-foreground">
              {t("shortcuts.title")}
            </h2>
            <dl className="flex flex-col gap-2.5">
              <div className="flex items-center gap-2">
                <dt className="flex gap-2">
                  <kbd className={kbd}>↑</kbd>
                  <kbd className={kbd}>↓</kbd>
                </dt>
                <dd>{t("shortcuts.switchVideo")}</dd>
              </div>
              <div className="flex items-center gap-2">
                <dt>
                  <kbd className={kbd}>{t("shortcuts.space")}</kbd>
                </dt>
                <dd>{t("shortcuts.playPause")}</dd>
              </div>
              <div className="flex items-center gap-2">
                <dt>
                  <kbd className={kbd}>M</kbd>
                </dt>
                <dd>{t("shortcuts.mute")}</dd>
              </div>
            </dl>
          </section>
        )}
        <div className="flex items-center gap-2.5 p-1">
          <Avatar seed={userId} size="sm" />
          <span className="min-w-0 flex-1 truncate text-sm font-semibold">{t("account")}</span>
          <LogoutForm>
            <IconButton type="submit" tone="muted" label={t("logout")} icon={<LogOut aria-hidden="true" size={18} />} />
          </LogoutForm>
        </div>
      </div>
    </aside>
  );
}
