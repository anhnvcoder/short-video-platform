export const locales = ["vi", "en"] as const;
export type Locale = (typeof locales)[number];

export const defaultLocale: Locale = "vi";

// Set when the user picks a language; it wins over Accept-Language.
export const localeCookie = "svp_locale";

// Dates render the same on the server and in the browser only with one fixed time zone; the audience is in Vietnam.
export const timeZone = "Asia/Ho_Chi_Minh";

export function isLocale(value: string | undefined): value is Locale {
  return (locales as readonly string[]).includes(value ?? "");
}
