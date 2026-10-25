import { reloadOnceOnSkew } from "./skew-reload";

// Error reports of the browser. No Sentry SDK in the
// browser bundle: a small report goes to the app's own POST /monitoring, and the server builds the event, scrubs it
// and sends it to GlitchTip. The browser knows no DSN and sends no cookie.

// Reports per page load; a loop that throws costs at most this many requests.
const maxReports = 10;

let sent = 0;
// The server answered 404: reporting is off there, so nothing more is sent from this page.
let off = false;
const seen = new Set<string>();

interface DebugIdGlobal {
  // Turbopack's debug id snippet keys each chunk's debug id by an Error stack taken inside that chunk.
  _debugIds?: Record<string, string>;
}

// A chunk's URL in a stack line, without query (`?dpl=`), line or column: the host may carry a port, the path no colon.
const chunkUrlPattern = /https?:\/\/[^\s/]+\/[^\s?#:)]+/;

function debugIdsOf(stack: string): Record<string, string> {
  const ids: Record<string, string> = {};
  for (const [chunkStack, id] of Object.entries((globalThis as DebugIdGlobal)._debugIds ?? {})) {
    const url = chunkUrlPattern.exec(chunkStack)?.[0];
    if (url !== undefined && stack.includes(url) && Object.keys(ids).length < 64) {
      ids[url] = id;
    }
  }
  return ids;
}

// A server error carries a digest and was reported by the server already; its message here is a generic one.
function hasDigest(error: unknown): boolean {
  return typeof error === "object" && error !== null && "digest" in error;
}

export function reportClientError(error: unknown): void {
  if (off || sent >= maxReports || hasDigest(error)) {
    return;
  }
  // A thrown non-Error (a string, a rejected value) has no stack; a new Error would only show the reporter's own.
  const { name, message, stack = "" } = error instanceof Error ? error : { name: "Error", message: String(error) };
  // The same error from the same place is sent once: a render error comes back on every retry.
  const firstFrame = stack.split("\n").find((line) => /:\d+:\d+\)?$/.test(line)) ?? "";
  const key = `${name}\n${message}\n${firstFrame}`;
  if (seen.has(key)) {
    return;
  }
  seen.add(key);
  sent++;
  const body = JSON.stringify({
    name: name.slice(0, 200),
    message: message.slice(0, 1_000),
    stack: stack.slice(0, 16_000),
    path: location.pathname.slice(0, 500),
    debug_ids: debugIdsOf(stack),
  });
  // text/plain needs no preflight; keepalive lets the report leave while the page unloads. Never retried.
  fetch(`${location.origin}/monitoring`, {
    method: "POST",
    keepalive: true,
    credentials: "omit",
    headers: { "Content-Type": "text/plain" },
    body,
  }).then(
    (response) => {
      off ||= response.status === 404;
    },
    () => {},
  );
}

// What every place that catches an error does with it: reload once for a build skew, report anything else.
export function handleClientError(error: unknown): void {
  if (!reloadOnceOnSkew(error)) {
    reportClientError(error);
  }
}
