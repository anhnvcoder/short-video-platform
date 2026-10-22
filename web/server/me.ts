import "server-only";
import { cookies, headers } from "next/headers";
import { cache } from "react";
import { z } from "zod";
import { serverEnv } from "./env";
import { gatewayClient } from "./gateway";
import { bffServices } from "./runtime";
import { sessionCookieName } from "./session";

// The logged-in user's own profile (GET /me) for the server render, called with the session's access token. The token
// stays in this module: only the profile is returned. The profile is decoration of the shell, so this never redirects
// and never ends a session: a missing session or a token the gateway refuses is for the page's own loader (and
// requireSession) to act on, which keeps the layout out of any redirect loop.

// The shell waits at most this long for the name; past it, the avatar alone shows.
const meTimeoutMs = 2000;

export interface MyProfile {
  userId: string;
  handle: string;
  displayName: string;
}

// The gateway's answer, checked: a handle outside the stored form would end up in a /u/<handle> link.
const profileSchema = z.object({
  user_id: z.uuid(),
  handle: z.string().regex(/^[a-z][a-z0-9_]{2,29}$/),
  display_name: z.string().min(1),
});

// The profile, or null when it cannot be had now (no session, refresh not possible, gateway error, timeout). Cached
// for the request, so the layout and a page that both need it call the gateway once.
export const loadMyProfile = cache(async (options: { timeoutMs?: number } = {}): Promise<MyProfile | null> => {
  const sid = (await cookies()).get(sessionCookieName(serverEnv().secure))?.value;
  if (!sid) {
    return null;
  }
  try {
    const { env, access } = await bffServices();
    const forwardedFor = (await headers()).get("x-forwarded-for");
    const result = await access.access(sid, forwardedFor);
    if (result.kind !== "ok") {
      return null;
    }
    const client = gatewayClient(env.gatewayOrigin, result.session.access_token, forwardedFor);
    const { data, response } = await client.GET("/me", {
      signal: AbortSignal.timeout(options.timeoutMs ?? meTimeoutMs),
    });
    const profile = response.ok ? profileSchema.safeParse(data).data : undefined;
    return profile ? { userId: profile.user_id, handle: profile.handle, displayName: profile.display_name } : null;
  } catch {
    return null;
  }
});
