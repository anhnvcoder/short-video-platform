"use client";

import { useLocale } from "next-intl";
import { ErrorsIntlProvider } from "@/components/shell/errors-intl";
import { RouteError } from "@/components/shell/route-error";

// Error boundary of every page under the root layout. It brings its own messages: the provider of the root layout
// carries only the common namespace.
export default function ErrorPage({ error, retry }: { error: unknown; retry: () => void }) {
  return (
    <ErrorsIntlProvider locale={useLocale()}>
      <RouteError error={error} retry={retry} />
    </ErrorsIntlProvider>
  );
}
