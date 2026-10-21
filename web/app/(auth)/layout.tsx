import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import type { ReactNode } from "react";

// Frame of the login and register pages (web/design/AuthForm.dc.html; SVP Desktop.dc.html D07, D08): full screen on
// a phone, a card in the middle of a wide screen.
export default async function AuthLayout({ children }: { children: ReactNode }) {
  const [messages, common] = await Promise.all([getMessages(), getTranslations("common")]);
  return (
    <div className="flex min-h-dvh flex-col md:items-center md:justify-center md:p-6">
      <div className="flex flex-1 flex-col md:w-110 md:flex-none md:rounded-xl md:border md:border-border md:pb-4 md:shadow-raised">
        <header className="flex h-14 shrink-0 items-center justify-center">
          <span className="text-lg font-bold tracking-[0.1em]">{common("appName")}</span>
        </header>
        <main className="mx-auto flex w-full max-w-100 flex-1 flex-col px-6 pt-4 pb-8">
          {/* The forms are client components; they get the auth namespace only. */}
          <NextIntlClientProvider messages={{ auth: messages.auth }}>{children}</NextIntlClientProvider>
        </main>
      </div>
    </div>
  );
}
