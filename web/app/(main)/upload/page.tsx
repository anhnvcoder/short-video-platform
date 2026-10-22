import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { UploadRoute } from "@/features/upload/upload-route";

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations("upload"))("metaTitle") };
}

// Upload a video: the layout has already required a session.
export default function UploadPage() {
  return <UploadRoute />;
}
