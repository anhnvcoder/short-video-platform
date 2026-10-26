import type { Metadata } from "next";
import { getLocale, getMessages, getTimeZone, getTranslations } from "next-intl/server";
import { connection } from "next/server";
import type { ReactNode } from "react";
import { VitalsReporter } from "@/features/rum/vitals-reporter";
import { Providers } from "./providers";
import { beVietnamPro } from "./styles/fonts";
import "./styles/globals.css";
import { WebFonts } from "./styles/web-fonts";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("common");
  return { title: t("appName"), description: t("appDescription") };
}

export default async function RootLayout({ children }: { children: ReactNode }) {
  // Every page renders per request: the CSP nonce exists only in a request, and a page rendered at build time would
  // ship scripts without it, which the policy then blocks.
  await connection();
  const [locale, messages, timeZone] = await Promise.all([getLocale(), getMessages(), getTimeZone()]);
  return (
    <html lang={locale} className={beVietnamPro.variable}>
      <body>
        <Providers locale={locale} timeZone={timeZone} messages={{ common: messages.common }}>
          {children}
        </Providers>
        <VitalsReporter />
        <WebFonts />
      </body>
    </html>
  );
}
