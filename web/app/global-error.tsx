"use client";

import { useTranslations } from "next-intl";
import { ErrorsIntlProvider, useBrowserLocale } from "@/components/shell/errors-intl";
import { RouteError } from "@/components/shell/route-error";
import { beVietnamPro } from "./styles/fonts";
import "./styles/globals.css";
import { WebFonts } from "./styles/web-fonts";

// Replaces the root layout when that layout itself fails, so it renders its own document, styles and font, and finds
// the locale without the server.
export default function GlobalError({ error, retry }: { error: unknown; retry: () => void }) {
  const locale = useBrowserLocale();
  return (
    <html lang={locale} className={beVietnamPro.variable}>
      <body>
        <ErrorsIntlProvider locale={locale}>
          <DocumentTitle />
          <RouteError error={error} retry={retry} plainLinks />
        </ErrorsIntlProvider>
        <WebFonts />
      </body>
    </html>
  );
}

// global-error cannot export metadata; React puts this <title> in the head.
function DocumentTitle() {
  return <title>{useTranslations("errors")("generic.title")}</title>;
}
