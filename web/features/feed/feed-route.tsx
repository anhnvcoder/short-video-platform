import { NextIntlClientProvider, useMessages } from "next-intl";
import { Suspense } from "react";
import { FeedSkeleton } from "@/components/feed/feed-states";
import { requireSession } from "@/server/current-user";
import { serverEnv } from "@/server/env";
import { loadFirstFeedPage } from "@/server/feed";
import type { FeedKind } from "./api";
import { FeedFrame } from "./feed-frame";
import { FeedScreen } from "./feed-screen";

// Server part of the two feed pages. The first page can take up to the gateway's timeout, so it streams in behind a
// skeleton with the tabs: a tab switch shows the new tab at once instead of leaving the old feed frozen.
export function FeedRoute({ kind }: { kind: FeedKind }) {
  const messages = useMessages();
  return (
    // Only the feed's namespace goes to the browser.
    <NextIntlClientProvider messages={{ feed: messages.feed }}>
      <Suspense
        fallback={
          <FeedFrame kind={kind}>
            <FeedSkeleton />
          </FeedFrame>
        }
      >
        <LoadedFeed kind={kind} />
      </Suspense>
    </NextIntlClientProvider>
  );
}

// The media origin is passed down as a prop: it is not a secret, and the browser bundle reads no environment variable.
// When the first page cannot be had now, the client fetches it, after the Retry-After the gateway gave here if any.
async function LoadedFeed({ kind }: { kind: FeedKind }) {
  const [user, first] = await Promise.all([requireSession(), loadFirstFeedPage(kind)]);
  return (
    <FeedScreen
      kind={kind}
      initialPage={first.page}
      initialPageFetchedAt={first.fetchedAt}
      initialRetryAfterSeconds={first.retryAfterSeconds}
      mediaOrigin={serverEnv().mediaOrigin}
      currentUserId={user.userId}
    />
  );
}
