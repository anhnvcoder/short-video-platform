import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

// Locale and messages per request, read from i18n/request.ts (no locale prefix in the URL).
const withNextIntl = createNextIntlPlugin("./i18n/request.ts");

// The build id of the image (build arg SVP_BUILD_ID of deploy/docker/web.Dockerfile): the first 12 hex digits of the
// commit in CI, a hash of the build context on the dev path of k3d. Empty for `next build` of make web-check, next dev
// and compose, which then keep Next's own random build id.
const buildId = process.env.SVP_BUILD_ID || undefined;

const nextConfig: NextConfig = {
  // A self-contained server for the container image: server.js plus the node_modules it really uses.
  output: "standalone",
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
