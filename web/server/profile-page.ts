import "server-only";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { z } from "zod";
import {
  cleanVideoPage,
  isHandle,
  videoPageSize,
  type ProfileVideoPage,
  type ShownProfile,
} from "@/features/profile/api";
import { serverEnv } from "./env";
import { gatewayClient, retryAfterSeconds, type GatewayClient } from "./gateway";
import { pathHeader } from "./request-headers";
import { bffServices } from "./runtime";
import { sessionCookieName, type Session } from "./session";

// Data of the profile pages for the server render: the
// first page of "My videos" (/me) and another user's profile with the first page of their videos (/u/<handle>), called
// with the session's access token. The token stays in this module: only checked data is returned.

// Above the gateway's own 3 s per backend call, so the gateway's 504 arrives before this gives up.
const callTimeoutMs = 4000;

// What the server got of a first page of videos: the page and when the gateway gave it (ms since the epoch), or no page
// and, after a 429, the seconds the gateway asked to wait before the client asks again. Without a page the client
// fetches it through /api with its own retry policy.
export type FirstVideoPage = { page?: ProfileVideoPage; fetchedAt?: number; retryAfterSeconds?: number };

export type ProfilePage =
  | { kind: "profile"; profile: ShownProfile; videos: FirstVideoPage }
  // The handle is the viewer's own: the page sends them to /me.
  | { kind: "self" }
  // No user has this handle, or it cannot be one.
  | { kind: "not-found" }
  | { kind: "rate-limited"; retryAfterSeconds: number }
  // Gateway down, timeout, a refresh that cannot run now, an answer that does not hold a profile.
  | { kind: "unavailable" };

const profileSchema = z.object({
  user_id: z.uuid(),
  // Goes into the /u/<handle> link the page copies: the stored form only.
  handle: z.string().regex(/^[a-z][a-z0-9_]{2,29}$/),
  display_name: z.string().min(1),
  followed_by_me: z.boolean(),
});

type Usable = { kind: "ok"; sid: string; session: Session; client: GatewayClient; forwardedFor: string | null };
type Access = Usable | { kind: "login" } | { kind: "unavailable"; retryAfterSeconds?: number };

async function loginRedirect(): Promise<never> {
  redirect(`/login?next=${encodeURIComponent((await headers()).get(pathHeader) ?? "/")}`);
}

// The session with a usable access token. The cookie is looked at first: a visitor without one goes to the login page
// even while Redis is down.
async function sessionAccess(): Promise<Access> {
  const sid = (await cookies()).get(sessionCookieName(serverEnv().secure))?.value;
  if (!sid) {
    return { kind: "login" };
  }
  const { env, access } = await bffServices();
  const forwardedFor = (await headers()).get("x-forwarded-for");
  const result = await access.access(sid, forwardedFor);
  if (result.kind === "none" || result.kind === "expired") {
    return { kind: "login" };
  }
  if (result.kind === "unavailable") {
    return { kind: "unavailable", retryAfterSeconds: result.status === 429 ? result.retryAfterSeconds : undefined };
  }
  const client = gatewayClient(env.gatewayOrigin, result.session.access_token, forwardedFor);
  return { kind: "ok", sid, session: result.session, client, forwardedFor };
}

// The gateway refuses a token the session just handed out: the session is of no use. Ending it keeps the login page,
// which sends a logged-in visitor away, from sending the user straight back here.
async function endSession(usable: Usable): Promise<never> {
  const { access } = await bffServices();
  await access.end(usable.sid, usable.session, usable.forwardedFor).catch(() => {
    // Redis is down: the session stays until its TTL, and the next request tries again.
  });
  return loginRedirect();
}

type VideosAnswer = { data?: Parameters<typeof cleanVideoPage>[0]; response: Response };

async function firstVideoPage(
  usable: Usable,
  authorId: string,
  call: (init: { signal: AbortSignal }) => Promise<VideosAnswer>,
  timeoutMs: number,
): Promise<FirstVideoPage> {
  let answer: VideosAnswer;
  try {
    answer = await call({ signal: AbortSignal.timeout(timeoutMs) });
  } catch {
    return {};
  }
  const { data, response } = answer;
  if (response.status === 401) {
    return endSession(usable);
  }
  if (response.status === 429) {
    return { retryAfterSeconds: retryAfterSeconds(response) };
  }
  return response.ok && data ? { page: cleanVideoPage(data, authorId), fetchedAt: Date.now() } : {};
}

// The first page of the user's own videos, every state, for /me; a redirect to /login?next=<this page> when the
// session is gone or the gateway refuses its token.
export async function loadMyVideosFirstPage(options: { timeoutMs?: number } = {}): Promise<FirstVideoPage> {
  const usable = await sessionAccess();
  if (usable.kind === "login") {
    return loginRedirect();
  }
  if (usable.kind === "unavailable") {
    return { retryAfterSeconds: usable.retryAfterSeconds };
  }
  return firstVideoPage(
    usable,
    usable.session.user_id,
    (init) => usable.client.GET("/me/videos", { params: { query: { page_size: videoPageSize } }, ...init }),
    options.timeoutMs ?? callTimeoutMs,
  );
}

// The profile of `handle` (already lowered and checked by the page; checked again here), and the first page of the
// user's READY videos. Profiles need a login, so a missing session redirects to log in.
export async function loadProfilePage(handle: string, options: { timeoutMs?: number } = {}): Promise<ProfilePage> {
  if (!isHandle(handle)) {
    return { kind: "not-found" };
  }
  const usable = await sessionAccess();
  if (usable.kind === "login") {
    return loginRedirect();
  }
  if (usable.kind === "unavailable") {
    return usable.retryAfterSeconds === undefined
      ? { kind: "unavailable" }
      : { kind: "rate-limited", retryAfterSeconds: usable.retryAfterSeconds };
  }
  const timeoutMs = options.timeoutMs ?? callTimeoutMs;

  let answer;
  try {
    answer = await usable.client.GET("/profiles/{handle}", {
      params: { path: { handle } },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    return { kind: "unavailable" };
  }
  const { data, response } = answer;
  if (response.status === 401) {
    return endSession(usable);
  }
  if (response.status === 404) {
    return { kind: "not-found" };
  }
  if (response.status === 429) {
    return { kind: "rate-limited", retryAfterSeconds: retryAfterSeconds(response) };
  }
  const profile = response.ok ? profileSchema.safeParse(data).data : undefined;
  // A profile of another handle than the one asked for is not this page's.
  if (!profile || profile.handle !== handle) {
    return { kind: "unavailable" };
  }
  if (profile.user_id === usable.session.user_id) {
    return { kind: "self" };
  }

  const videos = await firstVideoPage(
    usable,
    profile.user_id,
    (init) =>
      usable.client.GET("/users/{user_id}/videos", {
        params: { path: { user_id: profile.user_id }, query: { page_size: videoPageSize } },
        ...init,
      }),
    timeoutMs,
  );
  return {
    kind: "profile",
    profile: {
      userId: profile.user_id,
      handle: profile.handle,
      displayName: profile.display_name,
      followedByMe: profile.followed_by_me,
    },
    videos,
  };
}
