import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { FeedRoute } from "@/features/feed/feed-route";

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations("feed"))("tabs.following") };
}

// Following: videos of the users the caller follows, newest first.
export default function FollowingPage() {
  return <FeedRoute kind="following" />;
}
