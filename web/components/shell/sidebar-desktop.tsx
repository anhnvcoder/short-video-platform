"use client";

import { House, LogOut, Plus, User } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import { Avatar, IconButton } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { LogoutForm } from "./logout-form";
import { currentNavItem } from "./nav";

const kbd =
  "inline-flex h-6 min-w-6 items-center justify-center rounded-[6px] border border-border-strong bg-surface-raised px-1.5 font-mono text-xs font-medium text-foreground";

const navLink =
  "flex min-h-12 items-center gap-3.5 rounded-md px-3 text-[15px] transition-colors duration-120 ease-out hover:bg-surface-hover hover:text-foreground";

// The current item has a background and a heavier weight, so it does not rely on color alone.
function navLinkState(current: boolean): string {
  return current ? "bg-surface-hover font-semibold text-foreground" : "font-medium text-muted";
}

// The name and handle the shell shows for the logged-in user.
export type ShellAccount = { displayName: string; handle: string };

type SidebarDesktopProps = {
  // Seed of the avatar color.
  userId: string;
  // Null when the profile could not be read: the block then shows the avatar and a generic label.
  account: ShellAccount | null;
  appName: string;
};

// Side bar of wide screens (web/design/SidebarDesktop.dc.html): Home and Profile, the Upload button, the feed's
// shortcuts on Home, the account with log out.
export function SidebarDesktop({ userId, account, appName }: SidebarDesktopProps) {
  const t = useTranslations("shell");
  const item = currentNavItem(usePathname());
  const current = item === "home";
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
          className={cn(navLink, focusRing, navLinkState(current))}
        >
          <House aria-hidden="true" size={22} />
          {t("home")}
        </Link>
        <Link
          href="/me"
          aria-current={item === "profile" ? "page" : undefined}
          className={cn(navLink, focusRing, navLinkState(item === "profile"))}
        >
          <User aria-hidden="true" size={22} />
          {t("profile")}
        </Link>
      </nav>
      <Link
        href="/upload"
        aria-current={item === "upload" ? "page" : undefined}
        className={cn(
          "mt-3 flex min-h-12 items-center justify-center gap-2.5 rounded-md bg-accent text-[15px] font-semibold text-accent-foreground transition-colors duration-120 ease-out hover:bg-accent-hover",
          focusRing,
        )}
      >
        <Plus aria-hidden="true" size={20} />
        {t("upload")}
      </Link>
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
          <Avatar seed={userId} name={account?.displayName} size="sm" />
          {account ? (
            // Each line is its own block, so a name in a right-to-left script does not move the handle.
            <div className="flex min-w-0 flex-1 flex-col">
              <span className="truncate text-sm font-semibold">{account.displayName}</span>
              <span className="truncate text-[13px] text-muted">@{account.handle}</span>
            </div>
          ) : (
            <span className="min-w-0 flex-1 truncate text-sm font-semibold">{t("account")}</span>
          )}
          <LogoutForm>
            <IconButton type="submit" tone="muted" label={t("logout")} icon={<LogOut aria-hidden="true" size={18} />} />
          </LogoutForm>
        </div>
      </div>
    </aside>
  );
}
