import "server-only";
import type { Breadcrumb, Event } from "@sentry/nextjs";

// What may reach the error tracker (threat model WEB-9, docs/adr/0019-web-k3d-supply-chain-observability.md, section 8),
// one set of rules for the server's own errors and for the browser's reports. Dropping free-form fields is the main
// defence; the patterns below are a second layer for what an error message may still carry.

// The two patterns the Go services redact (internal/sentryx): an email address and a JWT (every JWT starts with eyJ).
const emailPattern = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const jwtPattern = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g;
// 32 random bytes in base64url, exactly 43 characters: the session id and the refresh token.
const tokenPattern = /(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/g;
// The query of a URL: a presigned POST's X-Amz-* signature, `?next=`, ids. From the `?` to the end of the URL, or to
// the `:line:column` a stack frame puts after it.
const queryPattern = /\?[^\s"'<>#?]*=[^\s"'<>#]*?(?=:\d+(?::\d+)?\)?(?:\s|$)|[\s"'<>#]|$)/g;

// A run of text without white space longer than 1 KiB, redacted whole before the patterns above read it. No address,
// token or URL of the app is that long, and those patterns backtrack: their cost grows with the square of a run's
// length, and the browser's reports are unauthenticated (a 16 KB run took a third of a second of the event loop).
// Matching only where a run starts keeps this pattern itself linear.
const longRunPattern = /(?<!\S)\S{1025,}/g;

const redacted = "[redacted]";

export function scrubString(value: string): string {
  return value
    .replace(longRunPattern, redacted)
    .replace(queryPattern, "")
    .replace(jwtPattern, redacted)
    .replace(emailPattern, redacted)
    .replace(tokenPattern, redacted);
}

// Every string of a JSON-like value, keys included.
function scrubValue(value: unknown): unknown {
  if (typeof value === "string") {
    return scrubString(value);
  }
  if (Array.isArray(value)) {
    return value.map(scrubValue);
  }
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [scrubString(key), scrubValue(child)]));
  }
  return value;
}

// A URL without its query and fragment; undefined when it is not a URL.
export function withoutQuery(value: string): string | undefined {
  try {
    const url = new URL(value);
    return url.origin + url.pathname;
  } catch {
    return undefined;
  }
}

export interface ScrubOrigins {
  // Origins whose URLs never go into a breadcrumb: HLS and thumbnails, and the presigned POST of an upload.
  mediaOrigin: string;
  uploadOrigin: string;
}

function isOnOrigin(value: unknown, origin: string): boolean {
  if (typeof value !== "string") {
    return false;
  }
  try {
    return new URL(value).origin === origin;
  } catch {
    return false;
  }
}

export function scrubBreadcrumb(breadcrumb: Breadcrumb, { mediaOrigin, uploadOrigin }: ScrubOrigins): Breadcrumb {
  let data = breadcrumb.data;
  // A request to storage: its URL names the object, and an upload's carries the form's credential.
  if (
    (breadcrumb.category === "fetch" || breadcrumb.category === "xhr") &&
    (isOnOrigin(data?.url, mediaOrigin) || isOnOrigin(data?.url, uploadOrigin))
  ) {
    data = Object.fromEntries(Object.entries(data ?? {}).filter(([key]) => key !== "url"));
  }
  return scrubValue({ ...breadcrumb, data }) as Breadcrumb;
}

// Fields of an event dropped whole: the request (rebuilt below from its URL alone: no headers, cookies, body, query or
// client address), the user, the host name, free-form `extra`, the module list and what the SDK kept for itself
// (request headers among it). Breadcrumbs go through their own rules.
const droppedFields = new Set([
  "request",
  "user",
  "server_name",
  "extra",
  "modules",
  "sdkProcessingMetadata",
  "breadcrumbs",
]);

// The event as it may leave the process: every remaining string goes through the patterns.
export function scrubEvent<T extends Event>(event: T, origins: ScrubOrigins): T {
  const clean = scrubValue(Object.fromEntries(Object.entries(event).filter(([key]) => !droppedFields.has(key)))) as T;
  const url = event.request?.url === undefined ? undefined : withoutQuery(event.request.url);
  if (url !== undefined) {
    clean.request = { url: scrubString(url) };
  }
  if (event.breadcrumbs !== undefined) {
    clean.breadcrumbs = event.breadcrumbs.map((breadcrumb) => scrubBreadcrumb(breadcrumb, origins));
  }
  return clean;
}
