import "server-only";
import { randomBytes } from "node:crypto";

// Content-Security-Policy and the other security headers of every response (docs/adr/0016-web-client.md, section 6).

// 16 random bytes per request: a script injected into the page cannot guess it.
export function newNonce(): string {
  return randomBytes(16).toString("base64");
}

export interface CspOptions {
  nonce: string;
  mediaOrigin: string;
  // APP_ORIGIN is https.
  secure: boolean;
  // `next dev` only: React rebuilds server error stacks in the browser with eval. A production build never has it, and
  // nothing ever gets 'unsafe-inline'.
  dev: boolean;
}

export function contentSecurityPolicy({ nonce, mediaOrigin, secure, dev }: CspOptions): string {
  const directives = [
    "default-src 'self'",
    // 'self' is only the fallback for browsers that do not know 'strict-dynamic'.
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${dev ? " 'unsafe-eval'" : ""}`,
    `style-src 'self' 'nonce-${nonce}'`,
    `img-src 'self' ${mediaOrigin} data: blob:`,
    // hls.js feeds MediaSource through blob: URLs; without MSE the playlist URL goes straight into <video>.
    `media-src 'self' ${mediaOrigin} blob:`,
    // hls.js loads playlists and segments with XHR.
    `connect-src 'self' ${mediaOrigin}`,
    "worker-src 'self' blob:",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    ...(secure ? ["upgrade-insecure-requests"] : []),
  ];
  return directives.join("; ");
}

export function setSecurityHeaders(headers: Headers, csp: string, secure: boolean): void {
  headers.set("Content-Security-Policy", csp);
  if (secure) {
    headers.set("Strict-Transport-Security", "max-age=63072000; includeSubDomains");
  }
  headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()");
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  headers.set("X-Content-Type-Options", "nosniff");
}
