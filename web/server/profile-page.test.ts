import { delay, http, HttpResponse } from "msw";
import { getURLFromRedirectError } from "next/dist/client/components/redirect";
import { isRedirectError } from "next/dist/client/components/redirect-error";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { pathHeader } from "./request-headers";
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

const { loadMyVideosFirstPage, loadProfilePage } = await import("./profile-page");

const viewerId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const authorId = "01928c6e-7b3a-7cde-8f01-000000000002";
const readyId = "01928c6e-7b3a-7cde-8f01-000000000011";
const processingId = "01928c6e-7b3a-7cde-8f01-000000000012";

function video(id: string, author: string, status: string, extra: Record<string, unknown> = {}) {
  return { video_id: id, author_id: author, title: "Chiều", status, created_at: "2026-10-20T08:00:00Z", ...extra };
}

const ready = (author: string) =>
  video(readyId, author, "READY", {
    duration_ms: 58_000,
    published_at: "2026-10-20T08:01:00Z",
    playlist_url: "http://127.0.0.1:9000/v/master.m3u8",
    thumbnail_url: "http://127.0.0.1:9000/v/thumb.jpg",
    author: { user_id: author, handle: "minhanh", display_name: "Minh Anh" },
    stats: { view_count: 8300, like_count: 12, liked_by_me: true },
  });

// The cleaned READY video: only the fields the lists use.
const readyItem = {
  video_id: readyId,
  title: "Chiều",
  status: "READY",
  created_at: "2026-10-20T08:00:00Z",
  duration_ms: 58_000,
  published_at: "2026-10-20T08:01:00Z",
  thumbnail_url: "http://127.0.0.1:9000/v/thumb.jpg",
  view_count: 8300,
};

const profile = { user_id: authorId, handle: "minhanh", display_name: "Minh Anh", followed_by_me: true };

// Runs a loader that should redirect and returns where to.
async function redirectTarget(run: Promise<unknown>): Promise<string> {
  const error = await run.then(
    () => undefined,
    (thrown: unknown) => thrown,
  );
  expect(isRedirectError(error)).toBe(true);
  return isRedirectError(error) ? getURLFromRedirectError(error) : "";
}

// Records the gateway calls of a test.
function recordCalls() {
  const calls: { path: string; query: string; authorization: string | null; forwardedFor: string | null }[] = [];
  server.events.on("request:start", ({ request: call }) => {
    const url = new URL(call.url);
    if (url.origin === gatewayOrigin && !url.pathname.startsWith("/auth/")) {
      calls.push({
        path: url.pathname,
        query: url.search,
        authorization: call.headers.get("authorization"),
        forwardedFor: call.headers.get("x-forwarded-for"),
      });
    }
  });
  return calls;
}

beforeEach(() => {
  request.cookies.clear();
  request.headers = new Headers({ "x-forwarded-for": "203.0.113.7", [pathHeader]: "/u/minhanh?x=1" });
  request.services = undefined;
  server.events.removeAllListeners();
});

describe("profile loaders without a session", () => {
  it("send a visitor without a session cookie to log in and back, before any store is reached", async () => {
    expect(await redirectTarget(loadMyVideosFirstPage())).toBe(`/login?next=${encodeURIComponent("/u/minhanh?x=1")}`);
    expect(await redirectTarget(loadProfilePage("minhanh"))).toBe(
      `/login?next=${encodeURIComponent("/u/minhanh?x=1")}`,
    );
  });

  it.each(["MinhAnh", "ab", "_bob", "../me", "bób", "a".repeat(31)])(
    "loadProfilePage is not found for %j, without calling anything",
    async (handle) => {
      const calls = recordCalls();
      expect(await loadProfilePage(handle)).toEqual({ kind: "not-found" });
      expect(calls).toEqual([]);
    },
  );
});

describe.skipIf(!testRedisURL)("profile loaders on the test Redis", () => {
  const redis = useTestRedis();

  async function logIn(accessExpiresInMs?: number) {
    const tokens = fakeTokens(viewerId, accessExpiresInMs);
    const { sid } = await request.services!.store.create(viewerId, tokens);
    request.cookies.set("svp_sid", sid);
    return { sid, tokens };
  }

  beforeEach(() => {
    request.services = testServices(redis.client(), redis.prefix());
  });

  describe("loadMyVideosFirstPage", () => {
    it("asks GET /me/videos for 18 videos with the session's token and returns the cleaned page, without the token", async () => {
      const { tokens } = await logIn();
      const calls = recordCalls();
      server.use(
        http.get(`${gatewayOrigin}/me/videos`, () =>
          HttpResponse.json({
            items: [
              ready(viewerId),
              video(processingId, viewerId, "PROCESSING"),
              // Dropped: not a canonical id, not the caller's, a status this client does not know.
              video(readyId.toUpperCase(), viewerId, "READY"),
              video("01928c6e-7b3a-7cde-8f01-000000000013", authorId, "READY"),
              video("01928c6e-7b3a-7cde-8f01-000000000014", viewerId, "DELETED"),
            ],
            next_cursor: "abc",
          }),
        ),
      );

      const first = await loadMyVideosFirstPage();

      expect(first).toEqual({
        page: {
          items: [
            { ...readyItem },
            { video_id: processingId, title: "Chiều", status: "PROCESSING", created_at: "2026-10-20T08:00:00Z" },
          ],
          next_cursor: "abc",
        },
        fetchedAt: expect.any(Number),
      });
      expect(calls).toEqual([
        {
          path: "/me/videos",
          query: "?page_size=18",
          authorization: `Bearer ${tokens.access_token}`,
          forwardedFor: "203.0.113.7",
        },
      ]);
      const text = JSON.stringify(first);
      expect(text).not.toContain(tokens.access_token);
      expect(text).not.toContain(tokens.refresh_token);
      expect(text).not.toContain("eyJ");
    });

    it("refreshes an expired access token first", async () => {
      await logIn(-1000);
      const refreshed = fakeTokens(viewerId);
      let authorization: string | null = null;
      server.use(
        http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(refreshed))),
        http.get(`${gatewayOrigin}/me/videos`, ({ request: call }) => {
          authorization = call.headers.get("authorization");
          return HttpResponse.json({ items: [], next_cursor: "" });
        }),
      );
      expect((await loadMyVideosFirstPage()).page).toEqual({ items: [], next_cursor: "" });
      expect(authorization).toBe(`Bearer ${refreshed.access_token}`);
    });

    it("sends an unknown sid to log in", async () => {
      request.cookies.set("svp_sid", "b".repeat(43));
      expect(await redirectTarget(loadMyVideosFirstPage())).toMatch(/^\/login\?next=/);
    });

    it("ends the session and sends the user to log in when the gateway refuses the token", async () => {
      const { sid, tokens } = await logIn();
      const logouts = recordLogouts();
      server.use(http.get(`${gatewayOrigin}/me/videos`, () => gatewayProblem(401, "UNAUTHENTICATED")));
      expect(await redirectTarget(loadMyVideosFirstPage())).toBe(`/login?next=${encodeURIComponent("/u/minhanh?x=1")}`);
      expect(await request.services!.store.get(sid)).toBeNull();
      expect(logouts).toEqual([tokens.refresh_token]);
    });

    it("hands the Retry-After of a 429 to the client", async () => {
      await logIn();
      server.use(
        http.get(`${gatewayOrigin}/me/videos`, () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "7" })),
      );
      expect(await loadMyVideosFirstPage()).toEqual({ retryAfterSeconds: 7 });
    });

    it.each([
      ["503", () => gatewayProblem(503, "UNAVAILABLE")],
      ["a network error", () => HttpResponse.error()],
    ])("leaves the first page to the client on %s", async (_name, answer) => {
      await logIn();
      server.use(http.get(`${gatewayOrigin}/me/videos`, answer));
      expect(await loadMyVideosFirstPage()).toEqual({});
    });

    it("gives up on a gateway that does not answer in time", async () => {
      await logIn();
      server.use(
        http.get(`${gatewayOrigin}/me/videos`, async () => {
          await delay(1000);
          return HttpResponse.json({ items: [], next_cursor: "" });
        }),
      );
      expect(await loadMyVideosFirstPage({ timeoutMs: 50 })).toEqual({});
    });
  });

  describe("loadProfilePage", () => {
    it("reads the profile, then the author's first 18 videos, and returns them without the token", async () => {
      const { tokens } = await logIn();
      const calls = recordCalls();
      server.use(
        http.get(`${gatewayOrigin}/profiles/minhanh`, () => HttpResponse.json(profile)),
        http.get(`${gatewayOrigin}/users/${authorId}/videos`, () =>
          HttpResponse.json({ items: [ready(authorId)], next_cursor: "" }),
        ),
      );

      const page = await loadProfilePage("minhanh");

      expect(page).toEqual({
        kind: "profile",
        profile: { userId: authorId, handle: "minhanh", displayName: "Minh Anh", followedByMe: true },
        videos: { page: { items: [readyItem], next_cursor: "" }, fetchedAt: expect.any(Number) },
      });
      expect(calls.map(({ path, query, authorization }) => ({ path, query, authorization }))).toEqual([
        { path: "/profiles/minhanh", query: "", authorization: `Bearer ${tokens.access_token}` },
        { path: `/users/${authorId}/videos`, query: "?page_size=18", authorization: `Bearer ${tokens.access_token}` },
      ]);
      expect(JSON.stringify(page)).not.toContain("eyJ");
    });

    it("keeps followed_by_me false as the gateway says", async () => {
      await logIn();
      server.use(
        http.get(`${gatewayOrigin}/profiles/minhanh`, () => HttpResponse.json({ ...profile, followed_by_me: false })),
        http.get(`${gatewayOrigin}/users/${authorId}/videos`, () => HttpResponse.json({ items: [], next_cursor: "" })),
      );
      expect(await loadProfilePage("minhanh")).toMatchObject({
        kind: "profile",
        profile: { followedByMe: false },
        videos: { page: { items: [] } },
      });
    });

    it("is the viewer's own page for their own handle, without listing videos", async () => {
      await logIn();
      const calls = recordCalls();
      server.use(
        http.get(`${gatewayOrigin}/profiles/lanphuong`, () =>
          HttpResponse.json({ user_id: viewerId, handle: "lanphuong", display_name: "Lan", followed_by_me: false }),
        ),
      );
      expect(await loadProfilePage("lanphuong")).toEqual({ kind: "self" });
      expect(calls.map((call) => call.path)).toEqual(["/profiles/lanphuong"]);
    });

    it("is not found on 404 USER_NOT_FOUND", async () => {
      await logIn();
      server.use(http.get(`${gatewayOrigin}/profiles/minhanh`, () => gatewayProblem(404, "USER_NOT_FOUND")));
      expect(await loadProfilePage("minhanh")).toEqual({ kind: "not-found" });
    });

    it("is rate limited on 429, with the gateway's Retry-After", async () => {
      await logIn();
      server.use(
        http.get(`${gatewayOrigin}/profiles/minhanh`, () =>
          gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "12" }),
        ),
      );
      expect(await loadProfilePage("minhanh")).toEqual({ kind: "rate-limited", retryAfterSeconds: 12 });
    });

    it.each([
      ["503", () => gatewayProblem(503, "UNAVAILABLE")],
      ["a network error", () => HttpResponse.error()],
      ["another handle", () => HttpResponse.json({ ...profile, handle: "someone" })],
      ["a handle not in the stored form", () => HttpResponse.json({ ...profile, handle: "../evil" })],
      ["no followed_by_me", () => HttpResponse.json({ user_id: authorId, handle: "minhanh", display_name: "M" })],
    ])("is unavailable on %s", async (_name, answer) => {
      await logIn();
      server.use(http.get(`${gatewayOrigin}/profiles/minhanh`, answer));
      expect(await loadProfilePage("minhanh")).toEqual({ kind: "unavailable" });
    });

    it("ends the session and sends the user to log in when the gateway refuses the token", async () => {
      const { sid } = await logIn();
      recordLogouts();
      server.use(http.get(`${gatewayOrigin}/profiles/minhanh`, () => gatewayProblem(401, "UNAUTHENTICATED")));
      expect(await redirectTarget(loadProfilePage("minhanh"))).toMatch(/^\/login\?next=/);
      expect(await request.services!.store.get(sid)).toBeNull();
    });

    it("shows the profile without videos when the list is rate limited, with the wait for the client", async () => {
      await logIn();
      server.use(
        http.get(`${gatewayOrigin}/profiles/minhanh`, () => HttpResponse.json(profile)),
        http.get(`${gatewayOrigin}/users/${authorId}/videos`, () =>
          gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "4" }),
        ),
      );
      expect(await loadProfilePage("minhanh")).toMatchObject({ kind: "profile", videos: { retryAfterSeconds: 4 } });
    });

    it("shows the profile and leaves the videos to the client when the list fails", async () => {
      await logIn();
      server.use(
        http.get(`${gatewayOrigin}/profiles/minhanh`, () => HttpResponse.json(profile)),
        http.get(`${gatewayOrigin}/users/${authorId}/videos`, () => gatewayProblem(503, "UNAVAILABLE")),
      );
      expect(await loadProfilePage("minhanh")).toMatchObject({ kind: "profile", videos: {} });
    });
  });
});
