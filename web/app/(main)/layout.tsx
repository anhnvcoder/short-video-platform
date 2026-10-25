import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import { Suspense, type ReactNode } from "react";
import { BottomNav } from "@/components/shell/bottom-nav";
import { linkPendingMessages } from "@/components/shell/link-pending-messages";
import { SidebarAccount, SidebarDesktop } from "@/components/shell/sidebar-desktop";
import { requireSession } from "@/server/current-user";
import { loadMyProfile } from "@/server/me";

// Frame of the pages that need a login: a side bar on wide screens, a bottom bar on small ones, the page in between.
// Without a usable session, requireSession redirects to /login?next=<this page>. The side bar shows the user's name
// and handle when GET /me answers; without them, the avatar alone. No token reaches the client components.
export default async function MainLayout({ children }: { children: ReactNode }) {
  const user = await requireSession();
  const [messages, common] = await Promise.all([getMessages(), getTranslations("common")]);
  // Only the navigation is wrapped, with only its namespace and the spinner of its links: the pages bring their own
  // providers.
  const shellMessages = { shell: messages.shell, ...linkPendingMessages(messages) };
  return (
    <div className="flex h-dvh flex-col md:flex-row">
      <NextIntlClientProvider messages={shellMessages}>
        <SidebarDesktop
          appName={common("appName")}
          account={
            // The name is decoration: the page streams without waiting for GET /me (up to its 2 s timeout), and only
            // the account block waits, with the avatar alone until the name arrives. The rest of the side bar, log out
            // included, is never replaced when it does: a click under way or the keyboard's focus on it is not lost.
            <Suspense fallback={<SidebarAccount userId={user.userId} account={null} />}>
              <AccountWithProfile userId={user.userId} />
            </Suspense>
          }
        />
      </NextIntlClientProvider>
      {/* The page fills what the bars leave: a feed sizes its items to this box, not to the viewport. */}
      <main className="relative min-h-0 min-w-0 flex-1">{children}</main>
      <NextIntlClientProvider messages={shellMessages}>
        <BottomNav />
      </NextIntlClientProvider>
    </div>
  );
}

async function AccountWithProfile({ userId }: { userId: string }) {
  const profile = await loadMyProfile();
  return (
    <SidebarAccount userId={userId} account={profile && { displayName: profile.displayName, handle: profile.handle }} />
  );
}
