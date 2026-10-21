import type { Locale } from "./config";
import type { Messages } from "./messages";

// Typed keys for useTranslations/getTranslations and a typed locale.
declare module "next-intl" {
  interface AppConfig {
    Locale: Locale;
    Messages: Messages;
  }
}
