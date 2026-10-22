import { delay, http, HttpResponse } from "msw";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import type { BffServices } from "./runtime";
import { accessTokenBody, fakeTokens, gatewayOrigin, gatewayProblem, recordLogouts, testServices } from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

const request = vi.hoisted(() => ({
  cookies: new Map<string, string>(),
  headers: new Headers(),
  services: undefined as BffServices | undefined,
}));

vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: (name: string) => {
      const value = request.cookies.get(name);
      return value === undefined ? undefined : { name, value };
    },
  }),
  headers: async () => request.headers,
}));

vi.mock("./runtime", () => ({
  bffServices: async () => {
    if (!request.services) {
      throw new Error("redis down");
    }
    return request.services;
  },
}));
vi.mock("./env", () => ({ serverEnv: () => request.services?.env ?? { secure: false } }));

const { loadMyProfile } = await import("./me");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const profile = { user_id: userId, handle: "minhanh", display_name: "Minh Anh" };

beforeEach(() => {
  request.cookies.clear();
  request.headers = new Headers({ "x-forwarded-for": "203.0.113.7" });
  request.services = undefined;
});

describe("loadMyProfile without a session store", () => {
  it("is null without a session cookie, before any store is reached", async () => {
    expect(await loadMyProfile()).toBeNull();
  });

  it("is null when the session store cannot be reached", async () => {
    request.cookies.set("svp_sid", "d".repeat(43));
    expect(await loadMyProfile()).toBeNull();
  });
});

describe.skipIf(!testRedisURL)("loadMyProfile on the test Redis", () => {
  const redis = useTestRedis();

  async function logIn(accessExpiresInMs?: number) {
    const tokens = fakeTokens(userId, accessExpiresInMs);
    const { sid } = await request.services!.store.create(userId, tokens);
    request.cookies.set("svp_sid", sid);
    return { sid, tokens };
  }

  beforeEach(() => {
    request.services = testServices(redis.client(), redis.prefix());
  });

  it("asks GET /me with the session's token and returns the profile, without the token", async () => {
    const { tokens } = await logIn();
    let seen: Request | undefined;
    server.use(
      http.get(`${gatewayOrigin}/me`, ({ request: call }) => {
        seen = call;
        return HttpResponse.json(profile);
      }),
    );

    const me = await loadMyProfile();

    expect(me).toEqual({ userId, handle: "minhanh", displayName: "Minh Anh" });
    expect(seen?.headers.get("authorization")).toBe(`Bearer ${tokens.access_token}`);
    expect(seen?.headers.get("x-forwarded-for")).toBe("203.0.113.7");
    const text = JSON.stringify(me);
    expect(text).not.toContain(tokens.access_token);
    expect(text).not.toContain(tokens.refresh_token);
    expect(text).not.toContain("eyJ");
  });

  it("refreshes an expired access token first, as every page does", async () => {
    await logIn(-1000);
    const refreshed = fakeTokens(userId);
    let authorization: string | null = null;
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(refreshed))),
      http.get(`${gatewayOrigin}/me`, ({ request: call }) => {
        authorization = call.headers.get("authorization");
        return HttpResponse.json(profile);
      }),
    );
    expect(await loadMyProfile()).toMatchObject({ handle: "minhanh" });
    expect(authorization).toBe(`Bearer ${refreshed.access_token}`);
  });

  it("is null for an unknown sid, without calling the gateway", async () => {
    request.cookies.set("svp_sid", "b".repeat(43));
    let calls = 0;
    server.use(
      http.get(`${gatewayOrigin}/me`, () => {
        calls++;
        return HttpResponse.json(profile);
      }),
    );
    expect(await loadMyProfile()).toBeNull();
    expect(calls).toBe(0);
  });

  it("is null when the refresh token is rejected, and redirects nowhere", async () => {
    await logIn(-1000);
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(401, "INVALID_REFRESH_TOKEN")));
    expect(await loadMyProfile()).toBeNull();
  });

  it("is null on a 401 of GET /me and leaves the session to the page (no redirect, no logout)", async () => {
    const { sid } = await logIn();
    const logouts = recordLogouts();
    server.use(http.get(`${gatewayOrigin}/me`, () => gatewayProblem(401, "UNAUTHENTICATED")));
    expect(await loadMyProfile()).toBeNull();
    expect(await request.services!.store.get(sid)).not.toBeNull();
    expect(logouts).toEqual([]);
  });

  it.each([
    ["404 USER_NOT_FOUND", () => gatewayProblem(404, "USER_NOT_FOUND")],
    ["429", () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "5" })],
    ["503", () => gatewayProblem(503, "UNAVAILABLE")],
    ["a network error", () => HttpResponse.error()],
    ["a handle not in the stored form", () => HttpResponse.json({ ...profile, handle: "../evil" })],
    ["a missing display name", () => HttpResponse.json({ user_id: userId, handle: "minhanh" })],
    ["a body that is not JSON", () => new HttpResponse("oops", { headers: { "Content-Type": "text/plain" } })],
  ])("is null on %s", async (_name, answer) => {
    await logIn();
    server.use(http.get(`${gatewayOrigin}/me`, answer));
    expect(await loadMyProfile()).toBeNull();
  });

  it("gives up on a gateway that does not answer in time", async () => {
    await logIn();
    server.use(
      http.get(`${gatewayOrigin}/me`, async () => {
        await delay(1000);
        return HttpResponse.json(profile);
      }),
    );
    expect(await loadMyProfile({ timeoutMs: 50 })).toBeNull();
  });
});
