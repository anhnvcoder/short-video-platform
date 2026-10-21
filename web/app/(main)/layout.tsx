import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import type { ReactNode } from "react";
import { BottomNav } from "@/components/shell/bottom-nav";
import { SidebarDesktop } from "@/components/shell/sidebar-desktop";
import { requireSession } from "@/server/current-user";

// Frame of the pages that need a login: a side bar on wide screens, a bottom bar on small ones, the page in between.
// Without a usable session, requireSession redirects to /login?next=<this page>.
export default async function MainLayout({ children }: { children: ReactNode }) {
  const user = await requireSession();
  const [messages, common] = await Promise.all([getMessages(), getTranslations("common")]);
  // Only the navigation is wrapped, with only its namespace: the pages bring their own providers.
  const shellMessages = { shell: messages.shell };
  return (
    <div className="flex h-dvh flex-col md:flex-row">
      <NextIntlClientProvider messages={shellMessages}>
        <SidebarDesktop userId={user.userId} appName={common("appName")} />
      </NextIntlClientProvider>
      {/* The page fills what the bars leave: a feed sizes its items to this box, not to the viewport. */}
      <main className="relative min-h-0 min-w-0 flex-1">{children}</main>
      <NextIntlClientProvider messages={shellMessages}>
        <BottomNav />
      </NextIntlClientProvider>
    </div>
  );
}
