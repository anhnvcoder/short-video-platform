import enAuth from "@/messages/en/auth.json";
import enCommon from "@/messages/en/common.json";
import enErrors from "@/messages/en/errors.json";
import enFeed from "@/messages/en/feed.json";
import enProfile from "@/messages/en/profile.json";
import enShare from "@/messages/en/share.json";
import enShell from "@/messages/en/shell.json";
import enUpload from "@/messages/en/upload.json";
import viAuth from "@/messages/vi/auth.json";
import viCommon from "@/messages/vi/common.json";
import viErrors from "@/messages/vi/errors.json";
import viFeed from "@/messages/vi/feed.json";
import viProfile from "@/messages/vi/profile.json";
import viShare from "@/messages/vi/share.json";
import viShell from "@/messages/vi/shell.json";
import viUpload from "@/messages/vi/upload.json";
import type { Locale } from "./config";

// Messages are split into one file per namespace and locale, so each part of the app edits its own files; this merges
// them into the object next-intl reads, keyed by namespace (useTranslations("common")). Vietnamese is the reference:
// the English object is typed by it, so a key missing in English fails the type check.
const vi = {
  common: viCommon,
  auth: viAuth,
  shell: viShell,
  errors: viErrors,
  feed: viFeed,
  upload: viUpload,
  profile: viProfile,
  share: viShare,
};

export type Messages = typeof vi;

const en: Messages = {
  common: enCommon,
  auth: enAuth,
  shell: enShell,
  errors: enErrors,
  feed: enFeed,
  upload: enUpload,
  profile: enProfile,
  share: enShare,
};

const byLocale: Record<Locale, Messages> = { vi, en };

export function messagesFor(locale: Locale): Messages {
  return byLocale[locale];
}
