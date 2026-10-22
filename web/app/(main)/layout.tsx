import { NextIntlClientProvider, type AbstractIntlMessages } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import { Suspense, type ReactNode } from "react";
import { BottomNav } from "@/components/shell/bottom-nav";
import { SidebarDesktop, type ShellAccount } from "@/components/shell/sidebar-desktop";
import { requireSession } from "@/server/current-user";
import { loadMyProfile } from "@/server/me";

type SidebarProps = { userId: string; appName: string; messages: AbstractIntlMessages };

// Frame of the pages that need a login: a side bar on wide screens, a bottom bar on small ones, the page in between.
// Without a usable session, requireSession redirects to /login?next=<this page>. The side bar shows the user's name
// and handle when GET /me answers; without them, the avatar alone. No token reaches the client components.
export default async function MainLayout({ children }: { children: ReactNode }) {
  const user = await requireSession();
  const [messages, common] = await Promise.all([getMessages(), getTranslations("common")]);
  // Only the navigation is wrapped, with only its namespace: the pages bring their own providers.
  const shellMessages = { shell: messages.shell };
  const sidebar = { userId: user.userId, appName: common("appName"), messages: shellMessages };
  return (
    <div className="flex h-dvh flex-col md:flex-row">
      {/* The name is decoration: the page streams without waiting for GET /me (up to its 2 s timeout). The side bar
          shows the avatar alone until the name arrives. */}
      <Suspense fallback={<Sidebar {...sidebar} account={null} />}>
        <SidebarWithAccount {...sidebar} />
      </Suspense>
      {/* The page fills what the bars leave: a feed sizes its items to this box, not to the viewport. */}
      <main className="relative min-h-0 min-w-0 flex-1">{children}</main>
      <NextIntlClientProvider messages={shellMessages}>
        <BottomNav />
      </NextIntlClientProvider>
    </div>
  );
}

async function SidebarWithAccount(props: SidebarProps) {
  const profile = await loadMyProfile();
  return <Sidebar {...props} account={profile && { displayName: profile.displayName, handle: profile.handle }} />;
}

function Sidebar({ userId, appName, messages, account }: SidebarProps & { account: ShellAccount | null }) {
  return (
    <NextIntlClientProvider messages={messages}>
      <SidebarDesktop userId={userId} account={account} appName={appName} />
    </NextIntlClientProvider>
  );
}
