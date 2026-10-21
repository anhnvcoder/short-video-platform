import type { NextRequest } from "next/server";
import { signOut } from "@/server/auth";
import { serverEnv } from "@/server/env";
import { bffServices } from "@/server/runtime";
import { serializeSessionCookie, sessionCookieName } from "@/server/session";

// POST /logout from a plain form, so it works without JavaScript (docs/adr/0016-web-client.md, section 5). A Route
// Handler rather than a Server Action, because the response needs Clear-Site-Data. proxy.ts has already checked the
// request's origin. The session cookie is cleared with the same name and attributes it was set with; Clear-Site-Data
// clears the cache only, not "cookies", which would also drop the language cookie.
export async function POST(request: NextRequest): Promise<Response> {
  const { secure } = serverEnv();
  const sid = request.cookies.get(sessionCookieName(secure))?.value;
  if (sid) {
    try {
      await signOut(await bffServices(), sid, request.headers.get("x-forwarded-for"));
    } catch {
      // Redis is down: the cookie still goes, and the session ends with its TTL.
      console.warn("deleting the session failed at logout");
    }
  }
  return new Response(null, {
    status: 303,
    headers: {
      Location: "/login",
      "Set-Cookie": serializeSessionCookie(secure, "", 0),
      "Clear-Site-Data": '"cache"',
      "Cache-Control": "no-store",
    },
  });
}
