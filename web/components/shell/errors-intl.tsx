"use client";

import { NextIntlClientProvider } from "next-intl";
import { useSyncExternalStore, type ReactNode } from "react";
import { defaultLocale, localeCookie, timeZone, type Locale } from "@/i18n/config";
import { resolveLocale } from "@/i18n/locale";
import enCommon from "@/messages/en/common.json";
import enErrors from "@/messages/en/errors.json";
import viCommon from "@/messages/vi/common.json";
import viErrors from "@/messages/vi/errors.json";

// Messages of the error pages, bundled rather than sent by the server: an error page must render when the server
// render that would send them has failed, and global-error replaces the root layout and its provider. Only these two
// small namespaces ship; the rest of the messages stays on the server.
const messages: Record<Locale, { common: typeof viCommon; errors: typeof viErrors }> = {
  vi: { common: viCommon, errors: viErrors },
  en: { common: enCommon, errors: enErrors },
};

export function ErrorsIntlProvider({ locale, children }: { locale: Locale; children: ReactNode }) {
  return (
    <NextIntlClientProvider locale={locale} timeZone={timeZone} messages={messages[locale]}>
      {children}
    </NextIntlClientProvider>
  );
}

function subscribe(): () => void {
  return () => {};
}

function browserLocale(): Locale {
  const cookie = document.cookie
    .split("; ")
    .find((entry) => entry.startsWith(`${localeCookie}=`))
    ?.slice(localeCookie.length + 1);
  return resolveLocale(cookie, navigator.languages.join(","));
}

// The locale when no server tells it (global-error), by the same rule as the server: the svp_locale cookie, else the
// browser's languages, else Vietnamese. The server render and the first client render use Vietnamese, so hydration
// matches; the browser's choice follows right after.
export function useBrowserLocale(): Locale {
  return useSyncExternalStore(subscribe, browserLocale, () => defaultLocale);
}
