import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { FeedRoute } from "@/features/feed/feed-route";

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations("feed"))("tabs.explore") };
}

// Explore: every video, newest first.
export default function ExplorePage() {
  return <FeedRoute kind="explore" />;
}
