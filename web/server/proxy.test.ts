import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const composeEnv = {
  GATEWAY_URL: "http://gateway:8080",
  REDIS_URL: "redis://host.docker.internal:6379/9",
  APP_ORIGIN: "http://localhost:3001",
  MEDIA_ORIGIN: "http://127.0.0.1:9000",
  UPLOAD_ORIGIN: "http://127.0.0.1:9000",
};

// Tests of web/proxy.ts, kept here because the unit run only looks in the source folders. The environment is read once
// per module instance, so every test loads proxy.ts afresh with its own.
async function loadProxy(env: Record<string, string> = composeEnv, nodeEnv = "production") {
  vi.resetModules();
  for (const [name, value] of Object.entries(env)) {
    vi.stubEnv(name, value);
  }
  vi.stubEnv("NODE_ENV", nodeEnv);
  return import("../proxy");
}

function request(path: string, method = "GET", headers: Record<string, string> = {}) {
  return new NextRequest(`http://localhost:3001${path}`, { method, headers });
}

// NextResponse.next({ request: { headers } }) hands the request headers to Next as x-middleware-request-<name>.
function forwarded(response: Response, name: string): string | null {
  return response.headers.get(`x-middleware-request-${name}`);
}

beforeEach(() => {
  vi.unstubAllEnvs();
});
afterEach(() => {
  vi.unstubAllEnvs();
});

describe("proxy", () => {
  it("puts one CSP with a fresh nonce on the request for the renderer and on the response", async () => {
    const { proxy } = await loadProxy();
    const response = proxy(request("/", "GET", { "content-security-policy": "script-src *", "x-nonce": "forged" }));

    const csp = response.headers.get("content-security-policy") ?? "";
    const nonce = /'nonce-([A-Za-z0-9+/=]+)'/.exec(csp)?.[1];
    expect(nonce).toBeDefined();
    expect(Buffer.from(nonce!, "base64")).toHaveLength(16);
    expect(forwarded(response, "content-security-policy")).toBe(csp);
    expect(forwarded(response, "x-nonce")).toBe(nonce);
    expect(csp).toBe(
      [
        "default-src 'self'",
        `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
        `style-src 'self' 'nonce-${nonce}'`,
        "img-src 'self' http://127.0.0.1:9000 data: blob:",
        "media-src 'self' http://127.0.0.1:9000 blob:",
        "connect-src 'self' http://127.0.0.1:9000",
        "worker-src 'self' blob:",
        "font-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "frame-ancestors 'none'",
      ].join("; "),
    );
    expect(csp).not.toContain("unsafe-inline");
    expect(csp).not.toContain("unsafe-eval");

    const second = proxy(request("/")).headers.get("content-security-policy");
    expect(second).not.toBe(csp);
  });

  it("lets the browser connect to the upload origin too, listed once when it is the media origin", async () => {
    const same = (await loadProxy()).proxy(request("/upload")).headers.get("content-security-policy") ?? "";
    expect(same).toContain("; connect-src 'self' http://127.0.0.1:9000; ");

    const { proxy } = await loadProxy({ ...composeEnv, UPLOAD_ORIGIN: "https://s3.svp.localhost:8443" });
    const csp = proxy(request("/upload")).headers.get("content-security-policy") ?? "";
    expect(csp).toContain("; connect-src 'self' http://127.0.0.1:9000 https://s3.svp.localhost:8443; ");
    // Only XHR goes to the upload origin: it serves no image, media or script.
    expect(csp.split("; ").filter((directive) => directive.includes("s3.svp.localhost"))).toHaveLength(1);
  });

  it("sets the other security headers; no HSTS on http://localhost", async () => {
    const { proxy } = await loadProxy();
    const headers = proxy(request("/login")).headers;
    expect(headers.get("referrer-policy")).toBe("strict-origin-when-cross-origin");
    expect(headers.get("permissions-policy")).toBe("camera=(), microphone=(), geolocation=(), payment=()");
    expect(headers.get("cross-origin-opener-policy")).toBe("same-origin");
    expect(headers.get("x-content-type-options")).toBe("nosniff");
    expect(headers.get("cache-control")).toBe("private, no-store");
    expect(headers.get("strict-transport-security")).toBeNull();
  });

  it("on https adds HSTS and upgrade-insecure-requests", async () => {
    const { proxy } = await loadProxy({ ...composeEnv, APP_ORIGIN: "https://svp.localhost:8443" });
    const headers = proxy(new NextRequest("https://svp.localhost:8443/")).headers;
    expect(headers.get("strict-transport-security")).toBe("max-age=63072000; includeSubDomains");
    expect(headers.get("content-security-policy")).toMatch(/; upgrade-insecure-requests$/);
  });

  it("allows 'unsafe-eval' under next dev only", async () => {
    const { proxy } = await loadProxy(composeEnv, "development");
    expect(proxy(request("/")).headers.get("content-security-policy")).toContain("'strict-dynamic' 'unsafe-eval'");
  });

  it("hands the renderer the page's path and query, overwriting the browser's header", async () => {
    const { proxy } = await loadProxy();
    const response = proxy(request("/following?x=1", "GET", { "x-svp-path": "//evil.example" }));
    expect(forwarded(response, "x-svp-path")).toBe("/following?x=1");
  });

  it.each([
    ["Sec-Fetch-Site: same-site", { "sec-fetch-site": "same-site" }],
    ["Sec-Fetch-Site: cross-site", { "sec-fetch-site": "cross-site" }],
    ["Sec-Fetch-Site: none", { "sec-fetch-site": "none" }],
    ["Origin: null", { origin: "null" }],
    ["no header", {}],
  ])("refuses a POST with %s: 403 CSRF_REJECTED, nothing reaches the route", async (_name, headers) => {
    const { proxy } = await loadProxy();
    for (const path of ["/login", "/api/videos/x/like", "/logout", "/monitoring", "/rum"]) {
      const response = proxy(request(path, "POST", headers));
      expect(response.status).toBe(403);
      expect(response.headers.get("content-type")).toBe("application/problem+json");
      expect(response.headers.get("x-middleware-next")).toBeNull();
      expect(response.headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
      expect(((await response.json()) as { code: string }).code).toBe("CSRF_REJECTED");
    }
  });

  it("lets the browser's same-origin beacon to /rum through: sendBeacon sends Sec-Fetch-Site, or Origin without it", async () => {
    const { proxy } = await loadProxy();
    const beacon = { "content-type": "text/plain;charset=UTF-8" };
    expect(
      proxy(request("/rum", "POST", { ...beacon, "sec-fetch-site": "same-origin" })).headers.get("x-middleware-next"),
    ).toBe("1");
    expect(
      proxy(request("/rum", "POST", { ...beacon, origin: "http://localhost:3001" })).headers.get("x-middleware-next"),
    ).toBe("1");
    expect(proxy(request("/rum", "POST", { ...beacon, origin: "http://localhost:3002" })).status).toBe(403);
  });

  it("lets a same-origin POST and a cross-site GET or HEAD through", async () => {
    const { proxy } = await loadProxy();
    expect(
      proxy(request("/logout", "POST", { "sec-fetch-site": "same-origin" })).headers.get("x-middleware-next"),
    ).toBe("1");
    expect(proxy(request("/", "GET", { "sec-fetch-site": "cross-site" })).headers.get("x-middleware-next")).toBe("1");
    expect(proxy(request("/", "HEAD", { "sec-fetch-site": "cross-site" })).headers.get("x-middleware-next")).toBe("1");
  });

  it("leaves only static files out of its matcher", async () => {
    const { config } = await loadProxy();
    const pattern = new RegExp(`^${config.matcher[0]!.replace("/((?!", "/(?!").replace(").*)", ").*")}$`);
    for (const path of ["/", "/login", "/api/feed/explore", "/logout", "/_next/data/x.json"]) {
      expect(pattern.test(path), path).toBe(true);
    }
    for (const path of ["/_next/static/chunks/a.js", "/_next/image", "/favicon.ico"]) {
      expect(pattern.test(path), path).toBe(false);
    }
  });
});
