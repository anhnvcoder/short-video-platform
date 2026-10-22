import { NextIntlClientProvider, useMessages } from "next-intl";
import { serverEnv } from "@/server/env";
import { UploadScreen } from "./upload-screen";

// Server part of the upload page. UPLOAD_ORIGIN goes down as a prop: it is public configuration, and the browser
// bundle reads no environment variable.
export function UploadRoute() {
  const messages = useMessages();
  return (
    // Only the upload namespace goes to the browser.
    <NextIntlClientProvider messages={{ upload: messages.upload }}>
      <UploadScreen uploadOrigin={serverEnv().uploadOrigin} />
    </NextIntlClientProvider>
  );
}
