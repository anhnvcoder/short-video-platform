import { getRequestConfig } from "next-intl/server";
import { cookies, headers } from "next/headers";
import { localeCookie, timeZone } from "./config";
import { resolveLocale } from "./locale";
import { messagesFor } from "./messages";

export default getRequestConfig(async () => {
  const locale = resolveLocale((await cookies()).get(localeCookie)?.value, (await headers()).get("accept-language"));
  return { locale, messages: messagesFor(locale), timeZone };
});
