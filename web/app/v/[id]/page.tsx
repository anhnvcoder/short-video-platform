import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import { ShareScreen } from "@/features/feed/share-screen";
import { rateLimitedError } from "@/server/current-user";
import { serverEnv } from "@/server/env";
import { isVideoId, loadVideoPage, videoMetadata } from "@/server/video-page";

type Props = { params: Promise<{ id: string }> };

// Open Graph and the title of the video for link previews; a page that is not a video gets the 404 title.
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const t = await getTranslations("share");
  const page = isVideoId(id) ? await loadVideoPage(id) : null;
  if (page?.kind === "video") {
    return videoMetadata(page.video, serverEnv(), t("metaTitle"));
  }
  return page === null || page.kind === "not-found" ? { title: t("notFound.title") } : {};
}

// The public share page /v/{id}. It is outside the
// (main) group: no login needed, no navigation bars. The id must be a canonical UUID, checked before anything is
// called; every video nobody may watch here gets the same 404.
export default async function VideoPage({ params }: Props) {
  const { id } = await params;
  if (!isVideoId(id)) {
    notFound();
  }
  const page = await loadVideoPage(id);
  if (page.kind === "not-found") {
    notFound();
  }
  if (page.kind === "rate-limited") {
    throw rateLimitedError(page.retryAfterSeconds);
  }
  if (page.kind === "unavailable") {
    throw new Error("the video cannot be loaded right now");
  }
  const [messages, common] = await Promise.all([getMessages(), getTranslations("common")]);
  return (
    // Only the namespaces the page's client components translate go to the browser.
    <NextIntlClientProvider messages={{ feed: messages.feed, share: messages.share }}>
      <ShareScreen
        video={page.video}
        viewerId={page.viewerId}
        mediaOrigin={serverEnv().mediaOrigin}
        loadedAt={page.loadedAt}
        appName={common("appName")}
      />
    </NextIntlClientProvider>
  );
}
