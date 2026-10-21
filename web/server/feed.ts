import "server-only";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { cleanPage, retryAfterSeconds, type FeedKind, type FeedPage } from "@/features/feed/api";
import { serverEnv } from "./env";
import { gatewayClient } from "./gateway";
import { pathHeader } from "./request-headers";
import { bffServices } from "./runtime";
import { sessionCookieName } from "./session";

// First page of a feed for the server render of the feed pages, called with the session's access token. The token
// stays in this module: only the page, its items filtered like the client's, is returned.

// Above the gateway's own 3 s per backend call, so the gateway's 504 arrives before this gives up.
const firstPageTimeoutMs = 4000;

// What the server got of the first page: the page and when the gateway gave it (ms since the epoch), or no page and,
// after a 429, the seconds the gateway asked to wait before the client asks again.
export type FirstFeedPage = { page?: FeedPage; fetchedAt?: number; retryAfterSeconds?: number };

async function loginRedirect(): Promise<never> {
  redirect(`/login?next=${encodeURIComponent((await headers()).get(pathHeader) ?? "/")}`);
}

// The page, a redirect to /login?next=<this page> when the session is gone or the gateway refuses its token, or no
// page when it cannot be had now (rate limit, gateway down, timeout): the client then fetches it through /api with its
// own retry policy, after the Retry-After of a 429 here.
export async function loadFirstFeedPage(kind: FeedKind, options: { timeoutMs?: number } = {}): Promise<FirstFeedPage> {
  // The cookie first: a visitor without one goes to the login page even while Redis is down.
  const sid = (await cookies()).get(sessionCookieName(serverEnv().secure))?.value;
  if (!sid) {
    return loginRedirect();
  }
  const { env, access } = await bffServices();
  const forwardedFor = (await headers()).get("x-forwarded-for");
  const result = await access.access(sid, forwardedFor);
  if (result.kind === "none" || result.kind === "expired") {
    return loginRedirect();
  }
  if (result.kind === "unavailable") {
    return {};
  }
  const { session } = result;

  let answer;
  try {
    const client = gatewayClient(env.gatewayOrigin, session.access_token, forwardedFor);
    const init = { signal: AbortSignal.timeout(options.timeoutMs ?? firstPageTimeoutMs) };
    answer = kind === "explore" ? await client.GET("/feed/explore", init) : await client.GET("/feed/following", init);
  } catch {
    return {};
  }
  const { data, response } = answer;
  if (response.status === 401) {
    // The gateway refuses a token the session just handed out: the session is of no use. Ending it keeps the login
    // page, which sends a logged-in visitor away, from sending the user straight back here.
    await access.end(sid, session, forwardedFor).catch(() => {
      // Redis is down: the session stays until its TTL, and the next request tries again.
    });
    return loginRedirect();
  }
  if (response.status === 429) {
    return { retryAfterSeconds: retryAfterSeconds(response) };
  }
  return response.ok && data ? { page: cleanPage(data), fetchedAt: Date.now() } : {};
}
