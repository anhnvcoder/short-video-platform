import "server-only";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { serverEnv } from "./env";
import { pathHeader } from "./request-headers";
import { bffServices } from "./runtime";
import { sessionCookieName } from "./session";
import type { AccessResult } from "./session-access";

// The logged-in user for Server Components. Only the user id leaves this module, never a token.

export interface CurrentUser {
  userId: string;
}

// The session of this request with a usable access token, refreshed when due. A refresh during render writes Redis
// only; the cookie carries a sid that does not change, so it needs no new Set-Cookie. The cookie is looked at before
// the session store is reached: a visitor without one is logged out even while Redis is down.
async function currentAccess(): Promise<AccessResult> {
  const sid = (await cookies()).get(sessionCookieName(serverEnv().secure))?.value;
  if (!sid) {
    return { kind: "none" };
  }
  const { access } = await bffServices();
  return access.access(sid, (await headers()).get("x-forwarded-for"));
}

// Longest wait a rate limit page counts down, so an odd Retry-After never shows hours.
const maxRateLimitWaitSeconds = 3600;

// An error whose digest tells error.tsx to show the rate limit page with its countdown: `SVP_RATE_LIMITED;<seconds>`
// (components/shell/route-error.tsx). Next keeps a digest set on a thrown error but replaces the message of every server
// error in production. Only the parsed whole number goes into the digest, never text from the gateway. Every page that
// shows the rate limit page throws this one, so the format and the cap stay the same everywhere.
export function rateLimitedError(retryAfterSeconds: number | undefined): Error {
  const seconds = Math.min(Math.max(Math.trunc(retryAfterSeconds ?? 60), 1), maxRateLimitWaitSeconds);
  return Object.assign(new Error("the gateway rate limited this request"), { digest: `SVP_RATE_LIMITED;${seconds}` });
}

// For pages that need a login: the user, or a redirect to /login?next=<this page>.
export async function requireSession(): Promise<CurrentUser> {
  const result = await currentAccess();
  if (result.kind === "unavailable") {
    throw result.status === 429
      ? rateLimitedError(result.retryAfterSeconds)
      : new Error("the session cannot be refreshed right now");
  }
  if (result.kind !== "ok") {
    redirect(`/login?next=${encodeURIComponent((await headers()).get(pathHeader) ?? "/")}`);
  }
  return { userId: result.session.user_id };
}

// The user, or null when the session is not usable right now: the same test as requireSession, so a page that sends a
// logged-in visitor away (the login page) and a page that needs a login never send a visitor back and forth, as they
// would for a session whose access token has expired while its refresh fails.
export async function getCurrentUser(): Promise<CurrentUser | null> {
  const result = await currentAccess();
  return result.kind === "ok" ? { userId: result.session.user_id } : null;
}
