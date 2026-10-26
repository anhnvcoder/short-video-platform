import { NextIntlClientProvider, useMessages } from "next-intl";
import { getLocale, getTranslations } from "next-intl/server";
import { linkPendingMessages } from "@/components/shell/link-pending-messages";
import { timeZone } from "@/i18n/config";
import { formatRelativeTime } from "@/lib/format";
import { requireSession } from "@/server/current-user";
import { serverEnv } from "@/server/env";
import { loadFirstFeedPage } from "@/server/feed";
import type { FeedKind } from "./api";
import { FeedScreen } from "./feed-screen";

// Server part of the two feed pages. The first page is in the page's HTML, not streamed in behind a skeleton: its first
// poster is the page's largest paint, and React reveals content streamed into a Suspense boundary in batches, up to
// about 300 ms after the previous reveal, so that paint would wait while the page's scripts load and run. The HTML
// therefore waits for the first page, at most the gateway's timeout (server/feed.ts); without a page the client fetches
// it behind the skeleton. A tab switch still answers at once: the feed screen lays the skeleton over the old tab while
// the router waits for the new one (feed-screen.tsx).
export function FeedRoute({ kind }: { kind: FeedKind }) {
  const messages = useMessages();
  return (
    // Only the feed's namespace, and the spinner of the empty following feed's link, go to the browser.
    <NextIntlClientProvider messages={{ feed: messages.feed, ...linkPendingMessages(messages) }}>
      <LoadedFeed kind={kind} />
    </NextIntlClientProvider>
  );
}

// When this render ran: the client counts "2 days ago" from it until its own clock takes over, so hydration reads the
// text the server wrote.
function renderTime(): number {
  return Date.now();
}

// The media origin is passed down as a prop: it is not a secret, and the browser bundle reads no environment variable.
// When the first page cannot be had now, the client fetches it, after the Retry-After the gateway gave here if any.
// The first page's "2 days ago" texts are written here too, so the browser hydrates them without formatting.
async function LoadedFeed({ kind }: { kind: FeedKind }) {
  const [user, first, locale, t] = await Promise.all([
    requireSession(),
    loadFirstFeedPage(kind),
    getLocale(),
    getTranslations("feed"),
  ]);
  const renderedAt = renderTime();
  const renderedAgo = first.page
    ? Object.fromEntries(
        first.page.items.map((item) => [
          item.published_at,
          formatRelativeTime(item.published_at, renderedAt, locale, timeZone, t("justNow")),
        ]),
      )
    : undefined;
  return (
    <FeedScreen
      kind={kind}
      initialPage={first.page}
      initialPageFetchedAt={first.fetchedAt}
      initialRetryAfterSeconds={first.retryAfterSeconds}
      mediaOrigin={serverEnv().mediaOrigin}
      currentUserId={user.userId}
      renderedAt={renderedAt}
      renderedAgo={renderedAgo}
    />
  );
}
