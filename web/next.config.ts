import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";
import { locales } from "./i18n/config";

// Locale and messages per request, read from i18n/request.ts (no locale prefix in the URL). Every message file under
// messages/ is compiled at build time, so neither the server nor the browser parses ICU syntax at run time: the
// browser bundle carries a small formatter instead of the ICU parser (about 8 kB gzip less on every page, all of it
// loaded before the page's first paint). Unit tests import the JSON files as they are and format them the usual way.
const withNextIntl = createNextIntlPlugin({
  requestConfig: "./i18n/request.ts",
  experimental: { messages: { path: "./messages", format: "json", locales, precompile: true } },
});

// The build id of the image (build arg SVP_BUILD_ID of deploy/docker/web.Dockerfile): the first 12 hex digits of the
// commit in CI, a hash of the build context on the dev path of k3d. Empty for `next build` of make web-check, next dev
// and compose, which then keep Next's own random build id.
const buildId = process.env.SVP_BUILD_ID || undefined;

const nextConfig: NextConfig = {
  // A self-contained server for the container image: server.js plus the node_modules it really uses.
  output: "standalone",
  // The OpenTelemetry SDK of server/telemetry/otel.ts is loaded by Node from node_modules, not bundled. Its ES module
  // builds load some dependencies with a require made by createRequire(import.meta.url) in another module, which the
  // bundler cannot follow: bundled, @grpc/grpc-js (the OTLP/gRPC exporters) was missing from the standalone output and
  // every export failed with "Cannot find module", while the server itself ran. Left external, each package is traced
  // with its own dependencies, @grpc/grpc-js included (the exporters also import it plainly). Every package the server
  // imports, so one copy of the SDK runs.
  serverExternalPackages: [
    "@opentelemetry/api",
    "@opentelemetry/core",
    "@opentelemetry/exporter-metrics-otlp-grpc",
    "@opentelemetry/exporter-trace-otlp-grpc",
    "@opentelemetry/instrumentation-http",
    "@opentelemetry/instrumentation-undici",
    "@opentelemetry/resources",
    "@opentelemetry/sdk-metrics",
    "@opentelemetry/sdk-node",
    "@opentelemetry/sdk-trace",
  ],
  // forwarded-parse is loaded by the http instrumentation only through such a require, with no plain import anywhere,
  // so no trace finds it; the require resolves it from the package's own directory in node_modules/.pnpm, where pnpm
  // links the package's dependencies. Without this copy the instrumentation hook fails to load and every route answers
  // 500 (make web-check starts the standalone server to catch that).
  outputFileTracingIncludes: {
    "/*": ["./node_modules/.pnpm/@opentelemetry+instrumentation-http@*/node_modules/forwarded-parse/**"],
  },
  // A known id instead of Next's random one: navigation requests and responses carry it, asset URLs get ?dpl=<id>, and
  // the client reloads once when a chunk or a Server Action of another build fails (features/monitoring/skew-reload.ts).
  deploymentId: buildId,
  // Thumbnails are already sized by media-worker; no image optimizer, so no sharp and no /_next/image endpoint.
  images: { unoptimized: true },
  poweredByHeader: false,
  // Maps of the browser bundle, so GlitchTip can show a browser error's stack in the source. They never reach a
  // browser: the image's build moves them out of .next/static and drops the sourceMappingURL comments, and they go to
  // GlitchTip only (make web-sourcemaps). next build of make web-check writes them too, so the bundle budgets measure
  // the chunks the image serves.
  productionBrowserSourceMaps: true,
  // A debug id in every chunk and its map (globalThis._debugIds at run time): a browser report names the id of each
  // chunk in its stack, and GlitchTip finds the map by that id, whatever the chunk's URL.
  turbopack: { debugIds: true },
  reactStrictMode: true,
  // `next dev` would otherwise write an AGENTS.md into the working tree on every start.
  agentRules: false,
  // No `env` key here on purpose: every value under it is copied into the browser bundle, whatever its name.
};

export default withNextIntl(nextConfig);
