import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { MyVideosRoute } from "@/features/profile/my-videos-route";

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations("profile"))("my.metaTitle") };
}

// "My videos": the layout has already required a session.
export default function MyVideosPage() {
  return <MyVideosRoute />;
}
