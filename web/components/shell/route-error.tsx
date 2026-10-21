"use client";

import { RotateCw, Timer, TriangleAlert } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui";
import { ErrorScreen, secondaryAction } from "./error-screen";
import { useCountdown } from "./use-countdown";

// Digest of a server error that means "rate limited": `SVP_RATE_LIMITED;<seconds>`. Next keeps a digest set on a thrown
// error, while it replaces the message of every server error by a generic one in production.
const rateLimitedPrefix = "SVP_RATE_LIMITED;";

function digestOf(error: unknown): string | undefined {
  if (typeof error === "object" && error !== null && "digest" in error && typeof error.digest === "string") {
    return error.digest;
  }
  return undefined;
}

// Seconds to wait when the error is a rate limit, else null.
export function rateLimitWait(error: unknown): number | null {
  const digest = digestOf(error);
  if (!digest?.startsWith(rateLimitedPrefix)) {
    return null;
  }
  const seconds = Number(digest.slice(rateLimitedPrefix.length));
  return Number.isInteger(seconds) && seconds >= 0 ? seconds : null;
}

type RouteErrorProps = {
  error: unknown;
  retry: () => void;
  // Plain links: global-error has replaced the root layout, so the home page loads as a new document.
  plainLinks?: boolean;
};

// Body of error.tsx and global-error.tsx. It shows only translated text and the digest that matches the server log,
// never the error's message or stack.
export function RouteError({ error, retry, plainLinks = false }: RouteErrorProps) {
  const t = useTranslations("errors");
  const appName = useTranslations("common")("appName");
  const wait = rateLimitWait(error);
  const left = useCountdown(wait, error);
  const home = plainLinks ? (
    // eslint-disable-next-line @next/next/no-html-link-for-pages -- a full page load on purpose: the root layout broke.
    <a href="/" className={secondaryAction}>
      {t("home")}
    </a>
  ) : (
    <Link href="/" className={secondaryAction}>
      {t("home")}
    </Link>
  );

  if (wait !== null) {
    return (
      <ErrorScreen
        appName={appName}
        status="429"
        icon={<Timer aria-hidden="true" size={44} className="text-warning" />}
        title={t("rateLimited.title")}
        body={t("rateLimited.body")}
      >
        <Button size="lg" disabled={left > 0} onClick={retry} className="tabular-nums">
          {left > 0 ? t("rateLimited.retryIn", { seconds: left }) : t("rateLimited.retry")}
        </Button>
        {home}
      </ErrorScreen>
    );
  }

  const digest = digestOf(error);
  return (
    <ErrorScreen
      appName={appName}
      icon={<TriangleAlert aria-hidden="true" size={44} className="text-danger" />}
      title={t("generic.title")}
      body={t("generic.body")}
      footnote={digest && <p className="font-mono text-xs leading-none text-muted">{t("errorCode", { digest })}</p>}
    >
      <Button size="lg" onClick={retry}>
        <RotateCw aria-hidden="true" size={18} />
        {t("generic.retry")}
      </Button>
      {home}
    </ErrorScreen>
  );
}
