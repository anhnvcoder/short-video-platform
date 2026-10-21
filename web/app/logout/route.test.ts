import { http } from "msw";
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import type { BffServices } from "@/server/runtime";
import { fakeTokens, gatewayOrigin, gatewayProblem, recordLogouts, testServices } from "@/server/testing/bff";
import { testRedisURL, useTestRedis } from "@/server/testing/redis";

const state = vi.hoisted(() => ({ services: undefined as BffServices | undefined }));

vi.mock("@/server/runtime", () => ({
  bffServices: async () => {
    if (!state.services) {
      throw new Error("no services");
    }
    return state.services;
  },
}));

vi.stubEnv("GATEWAY_URL", gatewayOrigin);
vi.stubEnv("REDIS_URL", "redis://127.0.0.1:6379/15");
vi.stubEnv("APP_ORIGIN", "http://localhost:3001");
vi.stubEnv("MEDIA_ORIGIN", "http://127.0.0.1:9000");

const { POST } = await import("./route");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";

function logoutRequest(sid?: string) {
  return new NextRequest("http://localhost:3001/logout", {
    method: "POST",
    headers: sid ? { cookie: `svp_locale=en; svp_sid=${sid}`, "x-forwarded-for": "203.0.113.5" } : {},
  });
}

function expectLoggedOutResponse(response: Response) {
  expect(response.status).toBe(303);
  expect(response.headers.get("location")).toBe("/login");
  expect(response.headers.get("set-cookie")).toBe("svp_sid=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0");
  expect(response.headers.get("clear-site-data")).toBe('"cache"');
  expect(response.headers.get("cache-control")).toBe("no-store");
}

beforeEach(() => {
  state.services = undefined;
});

describe("POST /logout", () => {
  it("without a session still clears the cookie and goes to /login", async () => {
    expectLoggedOutResponse(await POST(logoutRequest()));
  });

  it("when the session store is down still clears the cookie", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expectLoggedOutResponse(await POST(logoutRequest("a".repeat(43))));
    warn.mockRestore();
  });
});

describe.skipIf(!testRedisURL)("POST /logout on the test Redis", () => {
  const redis = useTestRedis();

  it("revokes the refresh token family, deletes the session and clears only the session cookie", async () => {
    state.services = testServices(redis.client(), redis.prefix());
    const { sid, session } = await state.services.store.create(userId, fakeTokens(userId));
    const logouts = recordLogouts();

    expectLoggedOutResponse(await POST(logoutRequest(sid)));

    expect(logouts).toEqual([session.refresh_token]);
    expect(await state.services.store.get(sid)).toBeNull();
    expect(await redis.client().keys(`${redis.prefix()}*`)).toEqual([]);
  });

  it("deletes the session even when the gateway's logout fails", async () => {
    state.services = testServices(redis.client(), redis.prefix());
    const { sid } = await state.services.store.create(userId, fakeTokens(userId));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    server.use(http.post(`${gatewayOrigin}/auth/logout`, () => gatewayProblem(500, "INTERNAL")));

    expectLoggedOutResponse(await POST(logoutRequest(sid)));
    expect(await state.services.store.get(sid)).toBeNull();
    warn.mockRestore();
  });
});
