import "server-only";
import { z } from "zod";

// Server configuration of the web client (docs/adr/0016-web-client.md, section 5). Read from process.env when a
// request needs it, never at `next build`: the image is built once and configured where it runs. Nothing here may
// reach the browser bundle, so no variable carries the prefix Next inlines into it, and next.config has no `env` key.

export interface ServerEnv {
  // Origin of the gateway, the only host the BFF ever calls.
  gatewayOrigin: string;
  // Session database: db 9 of Redis (Valkey in the cluster).
  redisURL: string;
  // Origin the browser uses for the app: CSRF checks, the cookie's form, the `next` redirect check.
  appOrigin: string;
  // Origin of HLS playlists, segments and thumbnails, allowed by the CSP.
  mediaOrigin: string;
  // APP_ORIGIN is https: Secure cookie with the __Host-Http- prefix, HSTS, upgrade-insecure-requests.
  secure: boolean;
}

// A bare origin: http(s), no credentials, path, query or fragment, written the way URL normalizes it.
function isOrigin(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return (url.protocol === "http:" || url.protocol === "https:") && url.origin === value;
}

const origin = z.string({ error: "is required" }).refine(isOrigin, "must be an http(s) origin without a path");

const schema = z.object({
  GATEWAY_URL: origin,
  REDIS_URL: z.string({ error: "is required" }).refine((value) => {
    try {
      const url = new URL(value);
      return url.protocol === "redis:" || url.protocol === "rediss:";
    } catch {
      return false;
    }
  }, "must be a redis:// or rediss:// URL"),
  // Plain http is for loopback only (compose and `make web-dev`), where nobody else is on the wire.
  APP_ORIGIN: origin.refine(
    (value) => !value.startsWith("http:") || new URL(value).hostname === "localhost",
    "must be https, or http only on host localhost",
  ),
  MEDIA_ORIGIN: origin,
});

// Validates the variables; the error names each bad variable and why, never its value (REDIS_URL may hold a password).
export function parseServerEnv(source: Record<string, string | undefined>): ServerEnv {
  const result = schema.safeParse(source);
  if (!result.success) {
    const problems = result.error.issues.map((issue) => `${issue.path.join(".")} ${issue.message}`);
    throw new Error(`invalid web server environment: ${problems.join("; ")}`);
  }
  const env = result.data;
  return {
    gatewayOrigin: env.GATEWAY_URL,
    redisURL: env.REDIS_URL,
    appOrigin: env.APP_ORIGIN,
    mediaOrigin: env.MEDIA_ORIGIN,
    secure: env.APP_ORIGIN.startsWith("https:"),
  };
}

let cached: ServerEnv | undefined;

// The environment of this process, parsed on first use.
export function serverEnv(): ServerEnv {
  cached ??= parseServerEnv(process.env);
  return cached;
}
