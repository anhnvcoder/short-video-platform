import { House, VideoOff } from "lucide-react";
import Link from "next/link";
import { getTranslations } from "next-intl/server";
import { ErrorScreen, primaryAction } from "@/components/shell/error-screen";

// Every video nobody may watch here: no such id, a malformed id, a video not READY (web/design/SVP Mobile.dc.html M39,
// SVP Desktop.dc.html D11).
export default async function VideoNotFound() {
  const [t, errors, common] = await Promise.all([
    getTranslations("share"),
    getTranslations("errors"),
    getTranslations("common"),
  ]);
  return (
    <ErrorScreen
      appName={common("appName")}
      status="404"
      icon={<VideoOff aria-hidden="true" size={44} className="text-muted" />}
      title={t("notFound.title")}
      body={t("notFound.body")}
    >
      <Link href="/" className={primaryAction}>
        <House aria-hidden="true" size={18} />
        {errors("home")}
      </Link>
    </ErrorScreen>
  );
}
