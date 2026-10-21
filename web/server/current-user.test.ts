import { http, HttpResponse } from "msw";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import type { BffServices } from "./runtime";
import { accessTokenBody, fakeTokens, gatewayOrigin, gatewayProblem, testServices } from "./testing/bff";
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

vi.mock("./runtime", () => ({ bffServices: async () => request.services }));
vi.mock("./env", () => ({ serverEnv: () => request.services!.env }));

const { getCurrentUser, requireSession } = await import("./current-user");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";

async function redirectTarget(run: Promise<unknown>): Promise<string> {
  const error = await run.then(
    () => undefined,
    (thrown: unknown) => thrown,
  );
  const digest = (error as { digest?: string } | undefined)?.digest ?? "";
  expect(digest).toMatch(/^NEXT_REDIRECT;/);
  return digest.split(";")[2] ?? "";
}

async function thrownBy(run: Promise<unknown>): Promise<(Error & { digest?: string }) | undefined> {
  return run.then(
    () => undefined,
    (thrown: unknown) => thrown as Error & { digest?: string },
  );
}

describe.skipIf(!testRedisURL)("current user on the test Redis", () => {
  const redis = useTestRedis();

  beforeEach(() => {
    request.cookies.clear();
    request.headers = new Headers({ "x-svp-path": "/following?x=1" });
    request.services = testServices(redis.client(), redis.prefix());
  });

  it("requireSession sends a logged-out visitor to /login with the page as next", async () => {
    expect(await redirectTarget(requireSession())).toBe("/login?next=%2Ffollowing%3Fx%3D1");
    request.cookies.set("svp_sid", "d".repeat(43));
    expect(await redirectTarget(requireSession())).toBe("/login?next=%2Ffollowing%3Fx%3D1");
  });

  it("requireSession and getCurrentUser give the user id and nothing else", async () => {
    const { sid } = await request.services!.store.create(userId, fakeTokens(userId));
    request.cookies.set("svp_sid", sid);
    expect(await requireSession()).toEqual({ userId });
    expect(await getCurrentUser()).toEqual({ userId });
  });

  it("getCurrentUser is null when logged out", async () => {
    expect(await getCurrentUser()).toBeNull();
  });

  it("an expired access token whose refresh fails is logged out for both, so login and pages do not loop", async () => {
    const { sid, session } = await request.services!.store.create(userId, fakeTokens(userId, -1000));
    request.cookies.set("svp_sid", sid);
    vi.spyOn(console, "warn").mockImplementation(() => {});
    let refreshes = 0;
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => {
        refreshes++;
        return gatewayProblem(503, "UNAVAILABLE");
      }),
    );

    expect(await getCurrentUser()).toBeNull();
    expect(await redirectTarget(requireSession())).toBe("/login?next=%2Ffollowing%3Fx%3D1");
    expect(refreshes).toBe(2);
    // The outcome is unknown: the session stays for the next request to try again.
    expect(await request.services!.store.get(sid)).toEqual(session);
    vi.restoreAllMocks();
  });

  it("requireSession throws a rate limit digest on a 429 refresh, bounded and built from the parsed seconds only", async () => {
    const { sid } = await request.services!.store.create(userId, fakeTokens(userId, -1000));
    request.cookies.set("svp_sid", sid);
    for (const [retryAfter, digest] of [
      ["7", "SVP_RATE_LIMITED;7"],
      ["99999", "SVP_RATE_LIMITED;3600"],
      ["soon", "SVP_RATE_LIMITED;1"],
    ] as const) {
      server.use(
        http.post(`${gatewayOrigin}/auth/refresh`, () =>
          gatewayProblem(429, "RATE_LIMITED", { "Retry-After": retryAfter }),
        ),
      );
      expect((await thrownBy(requireSession()))?.digest).toBe(digest);
    }
    // The session stays: the next request after the wait tries again.
    expect(await request.services!.store.get(sid)).not.toBeNull();
  });

  it("requireSession throws a plain error without a digest when the refresh is unavailable (503)", async () => {
    request.services = testServices(redis.client(), redis.prefix(), { waitMs: 50, pollMs: 10 });
    const { sid } = await request.services.store.create(userId, fakeTokens(userId, -1000));
    request.cookies.set("svp_sid", sid);
    // Another holder has the refresh lease and never writes: the wait ends unavailable.
    await request.services.store.acquireLock(sid, 5000);
    const error = await thrownBy(requireSession());
    expect(error).toBeInstanceOf(Error);
    expect(error?.digest).toBeUndefined();
  });

  it("getCurrentUser refreshes a token that is due, like requireSession", async () => {
    const { sid } = await request.services!.store.create(userId, fakeTokens(userId, -1000));
    request.cookies.set("svp_sid", sid);
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(fakeTokens(userId)))),
    );
    expect(await getCurrentUser()).toEqual({ userId });
    expect((await request.services!.store.get(sid))?.ver).toBe(2);
  });
});
