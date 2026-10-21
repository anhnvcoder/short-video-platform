import { delay, http, HttpResponse } from "msw";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import type { BffServices } from "./runtime";
import { fakeTokens, gatewayOrigin, gatewayProblem, recordLogouts, testServices } from "./testing/bff";
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

const { loadFirstFeedPage } = await import("./feed");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const videoId = "01928c6e-7b3a-7cde-8f01-000000000001";

const feedItem = {
  video_id: videoId,
  author_id: userId,
  title: "first",
  playlist_url: "http://127.0.0.1:9000/videos/v/index.m3u8",
  thumbnail_url: "http://127.0.0.1:9000/videos/v/thumb.jpg",
  duration_ms: 60_000,
  published_at: "2026-10-21T08:00:00Z",
  stats: { like_count: 1, view_count: 2, liked_by_me: false },
};

async function redirectTarget(run: Promise<unknown>): Promise<string> {
  const error = await run.then(
    () => undefined,
    (thrown: unknown) => thrown,
  );
  const digest = (error as { digest?: string } | undefined)?.digest ?? "";
  expect(digest).toMatch(/^NEXT_REDIRECT;/);
  return digest.split(";")[2] ?? "";
}

describe.skipIf(!testRedisURL)("first feed page on the test Redis", () => {
  const redis = useTestRedis();

  async function logIn(accessExpiresInMs?: number) {
    const tokens = fakeTokens(userId, accessExpiresInMs);
    const { sid } = await request.services!.store.create(userId, tokens);
    request.cookies.set("svp_sid", sid);
    return { sid, tokens };
  }

  beforeEach(() => {
    request.cookies.clear();
    request.headers = new Headers({ "x-svp-path": "/following?x=1", "x-forwarded-for": "203.0.113.7" });
    request.services = testServices(redis.client(), redis.prefix());
  });

  it("asks the gateway with the session's token and returns the page with bad ids dropped, without the token", async () => {
    const { tokens } = await logIn();
    let seen: Request | undefined;
    server.use(
      http.get(`${gatewayOrigin}/feed/following`, ({ request: call }) => {
        seen = call;
        return HttpResponse.json({ items: [feedItem, { ...feedItem, video_id: "../x" }], next_cursor: "c1" });
      }),
    );

    const before = Date.now();
    const first = await loadFirstFeedPage("following");

    expect(first).toEqual({ page: { items: [feedItem], next_cursor: "c1" }, fetchedAt: expect.any(Number) });
    // When the gateway answered: the client counts the page's age from it.
    expect(first.fetchedAt).toBeGreaterThanOrEqual(before);
    expect(first.fetchedAt).toBeLessThanOrEqual(Date.now());
    expect(seen?.headers.get("authorization")).toBe(`Bearer ${tokens.access_token}`);
    expect(seen?.headers.get("x-forwarded-for")).toBe("203.0.113.7");
    const text = JSON.stringify(first);
    expect(text).not.toContain(tokens.access_token);
    expect(text).not.toContain(tokens.refresh_token);
  });

  it("calls the explore feed for explore", async () => {
    await logIn();
    server.use(http.get(`${gatewayOrigin}/feed/explore`, () => HttpResponse.json({ items: [], next_cursor: "" })));
    expect(await loadFirstFeedPage("explore")).toEqual({
      page: { items: [], next_cursor: "" },
      fetchedAt: expect.any(Number),
    });
  });

  it("sends a visitor without a session to /login with the page as next", async () => {
    expect(await redirectTarget(loadFirstFeedPage("explore"))).toBe("/login?next=%2Ffollowing%3Fx%3D1");
    request.cookies.set("svp_sid", "d".repeat(43));
    expect(await redirectTarget(loadFirstFeedPage("explore"))).toBe("/login?next=%2Ffollowing%3Fx%3D1");
  });

  it("ends the session and sends the user to /login when the gateway refuses the token (401)", async () => {
    const { sid, tokens } = await logIn();
    const logouts = recordLogouts();
    server.use(http.get(`${gatewayOrigin}/feed/explore`, () => gatewayProblem(401, "UNAUTHENTICATED")));

    expect(await redirectTarget(loadFirstFeedPage("explore"))).toBe("/login?next=%2Ffollowing%3Fx%3D1");
    expect(await request.services!.store.get(sid)).toBeNull();
    expect(logouts).toEqual([tokens.refresh_token]);
  });

  it.each([
    ["429", () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "5" }), { retryAfterSeconds: 5 }],
    ["429 without Retry-After", () => gatewayProblem(429, "RATE_LIMITED"), { retryAfterSeconds: 1 }],
    ["503", () => gatewayProblem(503, "UNAVAILABLE"), {}],
    ["a network error", () => HttpResponse.error(), {}],
  ])("leaves the page to the client on %s and keeps the session", async (_, answer, expected) => {
    const { sid } = await logIn();
    server.use(http.get(`${gatewayOrigin}/feed/explore`, answer));

    expect(await loadFirstFeedPage("explore")).toEqual(expected);
    expect(await request.services!.store.get(sid)).not.toBeNull();
  });

  it("gives up on a gateway that does not answer in time", async () => {
    await logIn();
    server.use(
      http.get(`${gatewayOrigin}/feed/explore`, async () => {
        await delay(1000);
        return HttpResponse.json({ items: [feedItem], next_cursor: "" });
      }),
    );
    expect(await loadFirstFeedPage("explore", { timeoutMs: 50 })).toEqual({});
  });
});
