import { House, SearchX } from "lucide-react";
import Link from "next/link";
import { getTranslations } from "next-intl/server";
import { ErrorScreen, primaryAction } from "@/components/shell/error-screen";

export default async function NotFound() {
  const [t, common] = await Promise.all([getTranslations("errors"), getTranslations("common")]);
  return (
    <ErrorScreen
      appName={common("appName")}
      status="404"
      icon={<SearchX aria-hidden="true" size={44} className="text-muted" />}
      title={t("notFound.title")}
      body={t("notFound.body")}
    >
      <Link href="/" className={primaryAction}>
        <House aria-hidden="true" size={18} />
        {t("home")}
      </Link>
    </ErrorScreen>
  );
}
