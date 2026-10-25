import "server-only";
import type { NextRequest } from "next/server";
import { gatewayHeaders } from "./gateway";
import { problem } from "./problem";
import type { BffServices } from "./runtime";
import { sessionCookieName } from "./session";

// /api/* for client components: the browser calls the web server with its session cookie, and the web server calls
// the gateway with the session's access token. It is not an open proxy: only
// the routes below pass, the gateway URL is built from GATEWAY_URL and the checked path, never from a string of the
// client (WEB-7), and only the headers listed here go either way.

const id = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
// A handle as user-service stores it: the client sends
// the lowercase form, so upper case, an escape or any other character matches nothing.
const handle = "[a-z][a-z0-9_]{2,29}";

interface Route {
  // Matched against the path after /api, as received: a percent-escape, `..` or a non-canonical id matches nothing.
  pattern: RegExp;
  methods: readonly string[];
  query: readonly string[];
}

// The routes of services/gateway/openapi.yaml the web client uses. PATCH /me is not one: the display name changes
// through a Server Action. Nor is GET /public/videos/{id}: only the server of the share page calls it.
const routes: readonly Route[] = [
  { pattern: /^\/feed\/(?:explore|following)$/, methods: ["GET"], query: ["cursor", "page_size"] },
  { pattern: /^\/videos$/, methods: ["POST"], query: [] },
  { pattern: new RegExp(`^/videos/${id}$`), methods: ["GET"], query: [] },
  { pattern: new RegExp(`^/videos/${id}/complete$`), methods: ["POST"], query: [] },
  { pattern: new RegExp(`^/videos/${id}/like$`), methods: ["PUT", "DELETE"], query: [] },
  { pattern: new RegExp(`^/videos/${id}/views$`), methods: ["POST"], query: [] },
  { pattern: new RegExp(`^/me/following/${id}$`), methods: ["PUT", "DELETE"], query: [] },
  { pattern: /^\/me$/, methods: ["GET"], query: [] },
  { pattern: /^\/me\/videos$/, methods: ["GET"], query: ["cursor", "page_size"] },
  { pattern: new RegExp(`^/users/${id}/videos$`), methods: ["GET"], query: ["cursor", "page_size"] },
  { pattern: new RegExp(`^/profiles/${handle}$`), methods: ["GET"], query: [] },
];

// The gateway's own limit on a request body.
export const maxBodyBytes = 64 * 1024;

// The gateway answers within its 3 s per backend call; this only bounds a gateway that hangs.
const upstreamTimeoutMs = 10_000;

// Response headers passed on to the browser; everything else (Set-Cookie included) stays behind.
const passedResponseHeaders = ["content-type", "retry-after", "allow"];

type Body = { ok: true; bytes: Uint8Array<ArrayBuffer> | null } | { ok: false; response: Response };

async function readBody(request: NextRequest): Promise<Body> {
  if (request.body === null) {
    return { ok: true, bytes: null };
  }
  if (Number(request.headers.get("content-length") ?? 0) > maxBodyBytes) {
    return { ok: false, response: problem(413, "PAYLOAD_TOO_LARGE") };
  }
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    size += value.byteLength;
    if (size > maxBodyBytes) {
      await reader.cancel();
      return { ok: false, response: problem(413, "PAYLOAD_TOO_LARGE") };
    }
    chunks.push(value);
  }
  if (size === 0) {
    return { ok: true, bytes: null };
  }
  const mediaType = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
  if (mediaType !== "application/json") {
    return { ok: false, response: problem(415, "UNSUPPORTED_MEDIA_TYPE") };
  }
  return { ok: true, bytes: new Uint8Array(Buffer.concat(chunks)) };
}

export async function proxyApiRequest(request: NextRequest, services: BffServices): Promise<Response> {
  const { env, access } = services;
  const url = new URL(request.url);
  const path = url.pathname.startsWith("/api/") ? url.pathname.slice("/api".length) : "";
  const route = routes.find((candidate) => candidate.pattern.test(path));
  if (!route) {
    return problem(404, "NOT_FOUND");
  }
  if (!route.methods.includes(request.method)) {
    return problem(405, "METHOD_NOT_ALLOWED", { Allow: route.methods.join(", ") });
  }

  const query = new URLSearchParams();
  for (const [name, value] of url.searchParams) {
    if (!route.query.includes(name) || query.has(name)) {
      return problem(400, "INVALID_QUERY");
    }
    query.set(name, value);
  }

  const body = await readBody(request);
  if (!body.ok) {
    return body.response;
  }

  const sid = request.cookies.get(sessionCookieName(env.secure))?.value;
  if (!sid) {
    return problem(401, "UNAUTHENTICATED");
  }
  const forwardedFor = request.headers.get("x-forwarded-for");

  let result;
  try {
    result = await access.access(sid, forwardedFor);
  } catch {
    return problem(503, "UNAVAILABLE");
  }
  if (result.kind === "none" || result.kind === "expired") {
    return problem(401, "UNAUTHENTICATED");
  }
  if (result.kind === "unavailable") {
    const retry = result.retryAfterSeconds;
    return problem(
      result.status,
      result.status === 429 ? "RATE_LIMITED" : "UNAVAILABLE",
      retry ? { "Retry-After": String(retry) } : {},
    );
  }
  const { session } = result;

  const search = query.size > 0 ? `?${query.toString()}` : "";
  const target = new URL(path + search, env.gatewayOrigin);
  const headers = gatewayHeaders(session.access_token, forwardedFor);
  if (body.bytes !== null) {
    headers["Content-Type"] = "application/json";
  }

  let upstream: Response;
  try {
    upstream = await fetch(target, {
      method: request.method,
      headers,
      body: body.bytes,
      // The gateway never redirects; following one could lead the server anywhere.
      redirect: "manual",
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(upstreamTimeoutMs)]),
    });
  } catch (error) {
    return error instanceof DOMException && error.name === "TimeoutError"
      ? problem(504, "GATEWAY_TIMEOUT")
      : problem(502, "BAD_GATEWAY");
  }

  if (upstream.status === 401) {
    // The gateway refuses a token the session just handed out (fresh or refreshed): the session is of no use.
    await access.end(sid, session, forwardedFor).catch(() => {
      // Redis is down: the session stays until its TTL, and the next request tries again.
    });
  }

  const responseHeaders = new Headers({ "Cache-Control": "no-store" });
  for (const name of passedResponseHeaders) {
    const value = upstream.headers.get(name);
    if (value !== null) {
      responseHeaders.set(name, value);
    }
  }
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}
