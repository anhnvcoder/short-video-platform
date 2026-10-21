import { http, HttpResponse } from "msw";
import { NextRequest } from "next/server";
import { describe, expect, it } from "vitest";
import { server } from "@/lib/test/msw-server";
import { maxBodyBytes, proxyApiRequest } from "./api-proxy";
import type { BffServices } from "./runtime";
import { accessTokenBody, fakeTokens, gatewayOrigin, gatewayProblem, recordLogouts, testServices } from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const videoId = "01928c6e-7b3a-7cde-8f01-000000000001";
const appOrigin = "http://localhost:3001";

interface Seen {
  method: string;
  url: string;
  headers: Headers;
  body: string;
}

// Answers every request to the gateway but /auth/* with `respond` and records it; /auth/* falls through to the test's
// own handlers, and requests to any other host have no handler and fail the test (vitest.setup.ts).
function gateway(respond: () => Response = () => new HttpResponse(null, { status: 204 })): Seen[] {
  const seen: Seen[] = [];
  server.use(
    http.all(`${gatewayOrigin}/*`, async ({ request }) => {
      if (new URL(request.url).pathname.startsWith("/auth/")) {
        return undefined;
      }
      seen.push({ method: request.method, url: request.url, headers: request.headers, body: await request.text() });
      return respond();
    }),
  );
  return seen;
}

function apiRequest(
  path: string,
  init: { method?: string; sid?: string; headers?: Record<string, string>; body?: string } = {},
) {
  const headers = new Headers(init.headers);
  if (init.sid) {
    headers.set("cookie", `svp_sid=${init.sid}; svp_locale=vi`);
  }
  return new NextRequest(`${appOrigin}/api${path}`, { method: init.method ?? "GET", headers, body: init.body });
}

async function problemCode(response: Response): Promise<string> {
  expect(response.headers.get("content-type")).toBe("application/problem+json");
  return ((await response.json()) as { code: string }).code;
}

describe("proxyApiRequest without a session store", () => {
  // Rejections happen before the session is read, so no Redis is needed for them.
  const services = { env: testServices({} as never, "svp:test:none:").env } as BffServices;

  it.each([
    ["an unknown route", "GET", "/users"],
    ["the auth routes", "POST", "/auth/login"],
    ["upload, not in this part", "POST", "/videos"],
    ["a non-UUID id", "GET", "/videos/abc"],
    ["an upper case id", "GET", `/videos/${videoId.toUpperCase()}`],
    ["dot segments", "GET", `/videos/${videoId}/../like`],
    ["escaped dot segments", "GET", "/videos/%2e%2e/%2e%2e/healthz"],
    ["an escaped slash", "GET", `/videos/${videoId}%2Flike`],
    ["a trailing slash", "GET", "/feed/explore/"],
    ["an absolute URL in the path", "GET", "/http://169.254.169.254/latest"],
    ["a feed prefix", "GET", "/feed/explore2"],
  ])("answers 404 for %s", async (_name, method, path) => {
    const response = await proxyApiRequest(apiRequest(path, { method }), services);
    expect(response.status).toBe(404);
    expect(await problemCode(response)).toBe("NOT_FOUND");
  });

  it.each([
    ["POST", "/feed/explore", "GET"],
    ["DELETE", `/videos/${videoId}`, "GET"],
    ["GET", `/videos/${videoId}/like`, "PUT, DELETE"],
    ["PATCH", `/videos/${videoId}/like`, "PUT, DELETE"],
    ["GET", `/videos/${videoId}/views`, "POST"],
    ["POST", `/me/following/${videoId}`, "PUT, DELETE"],
    ["OPTIONS", "/feed/following", "GET"],
    ["HEAD", "/feed/following", "GET"],
  ])("answers 405 for %s %s with Allow: %s", async (method, path, allow) => {
    const response = await proxyApiRequest(apiRequest(path, { method }), services);
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe(allow);
  });

  it.each([
    ["an unknown parameter", "/feed/explore?limit=5"],
    ["a repeated parameter", "/feed/explore?cursor=a&cursor=b"],
    ["a query on a route without one", `/videos/${videoId}?page_size=3`],
  ])("answers 400 for %s", async (_name, path) => {
    const response = await proxyApiRequest(apiRequest(path), services);
    expect(response.status).toBe(400);
    expect(await problemCode(response)).toBe("INVALID_QUERY");
  });

  it("answers 401 without a session cookie", async () => {
    const response = await proxyApiRequest(apiRequest("/feed/explore"), services);
    expect(response.status).toBe(401);
    expect(await problemCode(response)).toBe("UNAUTHENTICATED");
  });

  it("refuses a body that is not JSON (415) or too large (413)", async () => {
    const path = `/videos/${videoId}/views`;
    const text = await proxyApiRequest(
      apiRequest(path, { method: "POST", headers: { "content-type": "text/plain" }, body: "x" }),
      services,
    );
    expect(text.status).toBe(415);
    const large = await proxyApiRequest(
      apiRequest(path, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ pad: "x".repeat(maxBodyBytes) }),
      }),
      services,
    );
    expect(large.status).toBe(413);
  });
});

describe.skipIf(!testRedisURL)("proxyApiRequest on the test Redis", () => {
  const redis = useTestRedis();

  async function withSession(accessExpiresInMs?: number) {
    const services = testServices(redis.client(), redis.prefix());
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, accessExpiresInMs));
    return { services, sid, session };
  }

  it("calls the gateway with the session's token, the browser's X-Forwarded-For and nothing else of the browser", async () => {
    const { services, sid, session } = await withSession();
    const seen = gateway(() =>
      HttpResponse.json(
        { items: [], next_cursor: "" },
        { headers: { "Set-Cookie": "gw=1; Path=/", "X-Internal": "1", "Retry-After": "3" } },
      ),
    );

    const response = await proxyApiRequest(
      apiRequest("/feed/following?page_size=5&cursor=abc%2B%2F", {
        sid,
        headers: {
          authorization: "Bearer attacker",
          "x-forwarded-for": "198.51.100.1, 10.42.0.9",
          "x-custom": "1",
          origin: appOrigin,
          traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        },
      }),
      services,
    );

    expect(response.status).toBe(200);
    expect(seen).toHaveLength(1);
    const call = seen[0]!;
    expect(call.method).toBe("GET");
    expect(new URL(call.url).origin).toBe(gatewayOrigin);
    expect(new URL(call.url).pathname).toBe("/feed/following");
    expect(Object.fromEntries(new URL(call.url).searchParams)).toEqual({ page_size: "5", cursor: "abc+/" });
    expect(call.headers.get("authorization")).toBe(`Bearer ${session.access_token}`);
    expect(call.headers.get("x-forwarded-for")).toBe("198.51.100.1, 10.42.0.9");
    for (const dropped of ["cookie", "x-custom", "origin", "traceparent"]) {
      expect(call.headers.get(dropped)).toBeNull();
    }

    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("x-internal")).toBeNull();
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("retry-after")).toBe("3");
    expect(response.headers.get("content-type")).toContain("application/json");
    expect(await response.json()).toEqual({ items: [], next_cursor: "" });
  });

  it("sends no X-Forwarded-For when the browser's request had none", async () => {
    const { services, sid } = await withSession();
    const seen = gateway();
    await proxyApiRequest(apiRequest(`/videos/${videoId}/like`, { method: "PUT", sid }), services);
    expect(seen[0]?.headers.get("x-forwarded-for")).toBeNull();
  });

  it.each([
    ["PUT", `/videos/${videoId}/like`, 204],
    ["DELETE", `/videos/${videoId}/like`, 204],
    ["POST", `/videos/${videoId}/views`, 202],
    ["PUT", `/me/following/${videoId}`, 204],
    ["DELETE", `/me/following/${videoId}`, 204],
    ["GET", `/videos/${videoId}`, 200],
    ["GET", "/feed/explore", 200],
  ])("passes %s %s and its status on", async (method, path, status) => {
    const { services, sid } = await withSession();
    const seen = gateway(() => (status === 200 ? HttpResponse.json({}) : new HttpResponse(null, { status })));
    const response = await proxyApiRequest(apiRequest(path, { method, sid }), services);
    expect(response.status).toBe(status);
    expect(seen[0]?.method).toBe(method);
    expect(new URL(seen[0]!.url).pathname).toBe(path);
  });

  it("passes a JSON body and its problem answer through", async () => {
    const { services, sid } = await withSession();
    const seen = gateway(() => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "12" }));
    const response = await proxyApiRequest(
      apiRequest(`/videos/${videoId}/views`, {
        method: "POST",
        sid,
        headers: { "content-type": "application/json; charset=utf-8" },
        body: "{}",
      }),
      services,
    );
    expect(seen[0]?.body).toBe("{}");
    expect(seen[0]?.headers.get("content-type")).toBe("application/json");
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("12");
    expect(await problemCode(response)).toBe("RATE_LIMITED");
  });

  it("answers 401 for an unknown sid", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const response = await proxyApiRequest(apiRequest("/feed/explore", { sid: "b".repeat(43) }), services);
    expect(response.status).toBe(401);
  });

  it("ends the session and answers 401 when the gateway refuses a freshly refreshed token", async () => {
    const { services, sid } = await withSession(10_000);
    const logouts = recordLogouts();
    const refreshed = fakeTokens(userId);
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(refreshed))));
    const seen = gateway(() => gatewayProblem(401, "INVALID_TOKEN"));

    const response = await proxyApiRequest(apiRequest("/feed/explore", { sid }), services);

    expect(seen[0]?.headers.get("authorization")).toBe(`Bearer ${refreshed.access_token}`);
    expect(response.status).toBe(401);
    expect(await services.store.get(sid)).toBeNull();
    expect(logouts).toEqual([refreshed.refresh_token]);
  });

  it("answers 401 when the refresh token is rejected", async () => {
    const { services, sid } = await withSession(-1000);
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(401, "INVALID_REFRESH_TOKEN")));
    const seen = gateway();
    const response = await proxyApiRequest(apiRequest("/feed/explore", { sid }), services);
    expect(response.status).toBe(401);
    expect(seen).toHaveLength(0);
    expect(await services.store.get(sid)).toBeNull();
  });

  it("never puts a token or the sid in a response (WEB-7)", async () => {
    const { services, sid, session } = await withSession(10_000);
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(fakeTokens(userId)))),
    );
    gateway(() => HttpResponse.json({ items: [{ video_id: videoId, title: "t" }], next_cursor: "" }));

    const responses = [
      await proxyApiRequest(apiRequest("/feed/explore", { sid }), services),
      await proxyApiRequest(apiRequest("/feed/explore?bad=1", { sid }), services),
      await proxyApiRequest(apiRequest("/nope", { sid }), services),
    ];
    for (const response of responses) {
      const text = [...response.headers].map(([k, v]) => `${k}: ${v}`).join("\n") + (await response.text());
      expect(text).not.toContain("eyJ");
      expect(text).not.toContain(session.refresh_token);
      expect(text).not.toContain(sid);
    }
  });
});
