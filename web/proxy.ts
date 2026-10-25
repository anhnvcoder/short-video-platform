import { NextResponse, type NextRequest } from "next/server";
import { contentSecurityPolicy, newNonce, setSecurityHeaders } from "@/server/csp";
import { passesCsrfCheck } from "@/server/csrf";
import { serverEnv } from "@/server/env";
import { problem } from "@/server/problem";
import { pathHeader } from "@/server/request-headers";

// Runs before every route but static files: the CSRF check of every
// request that may change state, then a fresh CSP nonce, put on the request for Next's renderer (it reads the nonce
// from the request's Content-Security-Policy header and stamps it on every script it emits) and on the response
// together with the other security headers.
export function proxy(request: NextRequest): NextResponse | Response {
  const env = serverEnv();
  const nonce = newNonce();
  const csp = contentSecurityPolicy({
    nonce,
    mediaOrigin: env.mediaOrigin,
    uploadOrigin: env.uploadOrigin,
    secure: env.secure,
    dev: process.env.NODE_ENV === "development",
  });

  if (!passesCsrfCheck(request.method, request.headers, env.appOrigin)) {
    const refused = problem(403, "CSRF_REJECTED");
    setSecurityHeaders(refused.headers, csp, env.secure);
    return refused;
  }

  // `set`, not `append`: a header of the same name from the browser must not reach the renderer.
  const headers = new Headers(request.headers);
  headers.set("Content-Security-Policy", csp);
  headers.set("x-nonce", nonce);
  headers.set(pathHeader, request.nextUrl.pathname + request.nextUrl.search);

  const response = NextResponse.next({ request: { headers } });
  setSecurityHeaders(response.headers, csp, env.secure);
  // Pages carry the user's session; no shared cache may keep them.
  response.headers.set("Cache-Control", "private, no-store");
  return response;
}

export const config = {
  // Only static files are left out. /api and prefetch requests are not: the CSRF check covers every unsafe method, and
  // headers the client sets (next-router-prefetch, purpose) must not decide whether it runs.
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
