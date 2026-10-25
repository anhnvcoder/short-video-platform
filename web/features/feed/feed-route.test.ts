import type { ReactElement } from "react";
import { describe, expect, it, vi } from "vitest";
import { messagesFor } from "@/i18n/messages";

// The page's messages, as the root layout's request config holds them.
vi.mock("next-intl", async (importOriginal) => ({
  ...(await importOriginal<typeof import("next-intl")>()),
  useMessages: () => messagesFor("vi"),
}));

const { FeedRoute } = await import("./feed-route");

describe("feed route", () => {
  it.each(["explore", "following"] as const)(
    "%s: gives the feed screen the feed's messages and the label of the empty feed's link spinner, nothing else",
    (kind) => {
      const element = FeedRoute({ kind }) as ReactElement<{ messages: unknown }>;

      // A nested provider replaces the root's messages: what is not here, the feed screen cannot translate.
      expect(element.props.messages).toEqual({
        feed: messagesFor("vi").feed,
        common: { loading: messagesFor("vi").common.loading },
      });
    },
  );
});
