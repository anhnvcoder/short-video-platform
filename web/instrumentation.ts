import type { Instrumentation } from "next";

// Server instrumentation, run once when the server starts (docs/adr/0019-web-k3d-supply-chain-observability.md,
// sections 8 and 10). Node runtime only; the modules are imported here, not at the top, so no other runtime bundles them.

export async function register(): Promise<void> {
  // `next build` loads this file too, without the server's environment.
  if (process.env.NEXT_RUNTIME !== "nodejs" || process.env.NEXT_PHASE === "phase-production-build") {
    return;
  }
  const [{ serverEnv }, { startTelemetry, addTraceTags }, { startErrorReporting }, Sentry] = await Promise.all([
    import("@/server/env"),
    import("@/server/telemetry/otel"),
    import("@/server/sentry/server"),
    import("@sentry/nextjs"),
  ]);
  const env = serverEnv();
  // OpenTelemetry first: the error tracker adds no tracer provider, propagator or context manager of its own, and its
  // events take their trace ids from the span OpenTelemetry has running.
  startTelemetry(env);
  startErrorReporting(env);
  Sentry.addEventProcessor(addTraceTags);
}

// Errors of a render, a Route Handler, a Server Action or the proxy that nothing caught. A no-op while reporting is
// off (no SENTRY_DSN): the SDK has no client then.
export const onRequestError: Instrumentation.onRequestError = async (error, request, context) => {
  if (process.env.NEXT_RUNTIME !== "nodejs") {
    return;
  }
  const { captureRequestError } = await import("@sentry/nextjs");
  captureRequestError(error, request, context);
};
