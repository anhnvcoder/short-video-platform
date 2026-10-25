import type { Messages } from "@/i18n/messages";

// The messages LinkPending translates, for every NextIntlClientProvider with a LinkPending inside. A nested provider
// replaces the messages of the one above it rather than adding to them, so without these the spinner's label would
// read the key "common.loading" whatever the root provider holds.
export function linkPendingMessages(messages: Messages) {
  return { common: { loading: messages.common.loading } };
}
