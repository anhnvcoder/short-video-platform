import "server-only";
import * as Sentry from "@sentry/nextjs";
import type { ServerEnv } from "../env";
import { browserEvent, type BrowserReport } from "./browser-report";
import { EventLimiter } from "./limiter";
import { scrubBreadcrumb, scrubEvent } from "./scrub";

// Error reporting of the web server to GlitchTip:
// errors only, no tracing, sessions or replay. The SDK is set up by hand, without withSentryConfig: no build plugin, no
// source map upload, no tunnel route of Sentry's own.

type Event = Parameters<NonNullable<Sentry.NodeOptions["beforeSend"]>>[0];

// What makes two events "the same" for the limiter: where it came from, what failed, on which route.
function fingerprintOf(event: Event): string {
  const exception = event.exception?.values?.[0];
  return [
    event.tags?.runtime,
    exception?.type ?? "",
    exception?.value ?? event.message ?? "",
    event.tags?.route ?? event.transaction ?? "",
  ].join("\u0000");
}

// Starts the SDK when SENTRY_DSN is set; without it nothing is reported and every capture is a no-op. `transport` is
// for tests only.
export function startErrorReporting(env: ServerEnv, transport?: Sentry.NodeOptions["transport"]): void {
  if (env.sentryDsn === null) {
    return;
  }
  const limiter = new EventLimiter();
  Sentry.init({
    dsn: env.sentryDsn,
    environment: env.sentryEnvironment,
    release: env.buildId,
    // The app sets OpenTelemetry up itself; Sentry adds no tracer provider, propagator or context manager of its own.
    enableOpenTelemetrySetup: false,
    // No default integration: they patch http and fetch (and add `sentry-trace`, `baggage` headers to the BFF's calls
    // to the gateway), record console and request data, and track sessions. Only chained causes (`error.cause`) stay.
    defaultIntegrations: false,
    integrations: [Sentry.linkedErrorsIntegration()],
    tracePropagationTargets: [],
    // Nothing personal is collected in the first place (Sentry 11 collects all of it by default); beforeSend still
    // drops and redacts whatever an event carries.
    dataCollection: { userInfo: false, cookies: false, httpHeaders: false, httpBodies: [], urlQueryParams: false },
    sendClientReports: false,
    initialScope: { tags: { service: "web", runtime: "server" } },
    beforeBreadcrumb: (breadcrumb) => scrubBreadcrumb(breadcrumb, env),
    beforeSend: (event) => {
      const clean = scrubEvent(event, env);
      return limiter.allow(fingerprintOf(clean), clean.tags?.runtime === "browser") ? clean : null;
    },
    ...(transport && { transport }),
  });
}

// Sends one browser report; the caller has validated it and counted it against the browser's budget. Returns at once:
// the SDK's transport sends in the background, so a slow or dead GlitchTip never holds the browser's request.
export function captureBrowserReport(report: BrowserReport, env: ServerEnv): void {
  Sentry.captureEvent(browserEvent(report, env));
}
