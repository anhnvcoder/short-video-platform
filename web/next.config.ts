import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

// Locale and messages per request, read from i18n/request.ts (no locale prefix in the URL).
const withNextIntl = createNextIntlPlugin("./i18n/request.ts");

const nextConfig: NextConfig = {
  // A self-contained server for the container image: server.js plus the node_modules it really uses.
  output: "standalone",
  // Thumbnails are already sized by media-worker; no image optimizer, so no sharp and no /_next/image endpoint.
  images: { unoptimized: true },
  poweredByHeader: false,
  // Source maps of the browser bundle would publish the whole client source.
  productionBrowserSourceMaps: false,
  reactStrictMode: true,
  // `next dev` would otherwise write an AGENTS.md into the working tree on every start.
  agentRules: false,
  // No `env` key here on purpose: every value under it is copied into the browser bundle, whatever its name.
};

export default withNextIntl(nextConfig);
