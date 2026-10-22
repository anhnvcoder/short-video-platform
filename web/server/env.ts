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
  // Origin of the storage the browser uploads to with a presigned POST, allowed by the CSP. Public configuration: the
  // upload page hands it to its client component, which sends a file only to an upload_url on this origin.
  uploadOrigin: string;
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

// Hosts of this machine as URL writes them: an IPv6 address keeps its brackets.
const loopbackHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);

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
  // Plain http is for loopback only (compose and `make web-dev`), where nobody else is on the wire. Zod runs every
  // refine even when an earlier one failed: a value that is not an origin passes here, keeping `new URL` from throwing
  // (a TypeError holding the value, out of safeParse) and leaving the error to the origin check.
  APP_ORIGIN: origin.refine(
    (value) => !isOrigin(value) || !value.startsWith("http:") || new URL(value).hostname === "localhost",
    "must be https, or http only on host localhost",
  ),
  MEDIA_ORIGIN: origin,
  // The browser posts the file and its 15-minute upload credential here, so plain http is for loopback only (MinIO of
  // compose on 127.0.0.1:9000), where the request never leaves the machine. Not an origin: as for APP_ORIGIN.
  UPLOAD_ORIGIN: origin.refine(
    (value) => !isOrigin(value) || !value.startsWith("http:") || loopbackHosts.has(new URL(value).hostname),
    "must be https, or http only on a loopback host",
  ),
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
    uploadOrigin: env.UPLOAD_ORIGIN,
    secure: env.APP_ORIGIN.startsWith("https:"),
  };
}

let cached: ServerEnv | undefined;

// The environment of this process, parsed on first use.
export function serverEnv(): ServerEnv {
  cached ??= parseServerEnv(process.env);
  return cached;
}
