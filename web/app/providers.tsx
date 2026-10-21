"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { NextIntlClientProvider, type AbstractIntlMessages } from "next-intl";
import { useState, type ReactNode } from "react";
import type { Locale } from "@/i18n/config";

type ProvidersProps = {
  locale: Locale;
  timeZone: string;
  // Only the namespaces client components translate; the rest stays on the server.
  messages: AbstractIntlMessages;
  children: ReactNode;
};

export function Providers({ locale, timeZone, messages, children }: ProvidersProps) {
  // One client per browser tab, created on first render: a module-level client would be shared by every request the
  // server renders.
  const [queryClient] = useState(() => new QueryClient());
  return (
    <NextIntlClientProvider locale={locale} timeZone={timeZone} messages={messages}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </NextIntlClientProvider>
  );
}
