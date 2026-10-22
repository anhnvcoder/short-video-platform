import { delay, http, HttpResponse } from "msw";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { FeedItem } from "@/features/feed/api";
import { server } from "@/lib/test/msw-server";
import type { BffServices } from "./runtime";
import {
  accessTokenBody,
  fakeTokens,
  gatewayOrigin,
  gatewayProblem,
  recordLogouts,
  testEnv,
  testServices,
} from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

const request = vi.hoisted(() => ({
  cookies: new Map<string, string>(),
  headers: new Headers(),
  services: undefined as BffServices | undefined,
  // Calls that reached the session store's services.
  servicesCalls: 0,
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
    request.servicesCalls++;
    if (!request.services) {
      throw new Error("redis down");
    }
    return request.services;
  },
}));
vi.mock("./env", () => ({ serverEnv: () => request.services?.env ?? testEnv }));

const { isVideoId, loadVideoPage, videoMetadata } = await import("./video-page");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const authorId = "01928c6e-7b3a-7cde-8f01-000000000002";
const videoId = "01928c6e-7b3a-7cde-8f01-000000000001";
const author = { user_id: authorId, handle: "minhanh", display_name: "Minh Anh" };

const publicVideo = {
  video_id: videoId,
  author_id: authorId,
  title: "Chiều Hà Nội",
  duration_ms: 42_000,
  playlist_url: "http://127.0.0.1:9000/videos/v/master.m3u8",
  thumbnail_url: "http://127.0.0.1:9000/videos/v/thumb.jpg",
  published_at: "2026-10-20T08:00:00Z",
  author,
  stats: { view_count: 1_200_000, like_count: 12_400 },
};

// GET /videos/{id} as the gateway answers it to a logged-in user.
const ownVideo = {
  ...publicVideo,
  status: "READY",
  created_at: "2026-10-20T07:58:00Z",
  stats: { view_count: 1_200_000, like_count: 12_401, liked_by_me: true },
};

// The page's video: the public one, with the guest's liked_by_me.
const guestItem = { ...publicVideo, stats: { ...publicVideo.stats, liked_by_me: false } };

// Records the gateway calls of a test and answers them.
function gateway(answers: { public?: () => Response; private?: () => Response }) {
  const calls: { path: string; authorization: string | null; forwardedFor: string | null }[] = [];
  const record = (call: Request) => {
    calls.push({
      path: new URL(call.url).pathname,
      authorization: call.headers.get("authorization"),
      forwardedFor: call.headers.get("x-forwarded-for"),
    });
  };
  server.use(
    http.get(`${gatewayOrigin}/public/videos/:id`, ({ request: call }) => {
      record(call);
      return answers.public?.() ?? HttpResponse.json(publicVideo);
    }),
    http.get(`${gatewayOrigin}/videos/:id`, ({ request: call }) => {
      record(call);
      return answers.private?.() ?? HttpResponse.json(ownVideo);
    }),
  );
  return calls;
}

beforeEach(() => {
  request.cookies.clear();
  request.headers = new Headers({ "x-forwarded-for": "203.0.113.7" });
  request.services = undefined;
  request.servicesCalls = 0;
});

describe("isVideoId", () => {
  it.each([
    [videoId, true],
    [videoId.toUpperCase(), false],
    [videoId.replaceAll("-", ""), false],
    ["..", false],
    [`${videoId}/..`, false],
    ["", false],
  ])("%j: %s", (value, expected) => {
    expect(isVideoId(value)).toBe(expected);
  });
});

describe("loadVideoPage for a guest (no session cookie)", () => {
  it("reads the public video without a token, passes X-Forwarded-For on, and never reaches the session store", async () => {
    const calls = gateway({});
    const page = await loadVideoPage(videoId);
    expect(page).toEqual({ kind: "video", video: guestItem, viewerId: null, loadedAt: expect.any(Number) });
    expect(calls).toEqual([{ path: `/public/videos/${videoId}`, authorization: null, forwardedFor: "203.0.113.7" }]);
    expect(request.servicesCalls).toBe(0);
  });

  it("sends no X-Forwarded-For when the request had none", async () => {
    request.headers = new Headers();
    const calls = gateway({});
    await loadVideoPage(videoId);
    expect(calls[0]?.forwardedFor).toBeNull();
  });

  it.each([videoId.toUpperCase(), "not-a-uuid", "..", "%2e%2e"])(
    "is not found for the id %j, without calling the gateway",
    async (id) => {
      const calls = gateway({});
      expect(await loadVideoPage(id)).toEqual({ kind: "not-found" });
      expect(calls).toEqual([]);
    },
  );

  it.each([
    ["404", () => gatewayProblem(404, "VIDEO_NOT_FOUND"), { kind: "not-found" }],
    [
      "429",
      () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "7" }),
      { kind: "rate-limited", retryAfterSeconds: 7 },
    ],
    [
      "429 without Retry-After",
      () => gatewayProblem(429, "RATE_LIMITED"),
      { kind: "rate-limited", retryAfterSeconds: 1 },
    ],
    ["400", () => gatewayProblem(400, "INVALID_UTF8"), { kind: "unavailable" }],
    ["503", () => gatewayProblem(503, "UNAVAILABLE"), { kind: "unavailable" }],
    ["a network error", () => HttpResponse.error(), { kind: "unavailable" }],
    [
      "a body that is not JSON",
      () => new HttpResponse("oops", { headers: { "Content-Type": "text/plain" } }),
      { kind: "unavailable" },
    ],
    ["another video", () => HttpResponse.json({ ...publicVideo, video_id: authorId }), { kind: "unavailable" }],
    [
      "an author id that is not a UUID",
      () => HttpResponse.json({ ...publicVideo, author_id: "../x" }),
      { kind: "unavailable" },
    ],
    ["no playlist", () => HttpResponse.json({ ...publicVideo, playlist_url: undefined }), { kind: "unavailable" }],
  ])("answers %s as %j", async (_, answer, expected) => {
    gateway({ public: answer });
    expect(await loadVideoPage(videoId)).toEqual(expected);
  });

  it("gives up on a gateway that does not answer in time", async () => {
    server.use(
      http.get(`${gatewayOrigin}/public/videos/:id`, async () => {
        await delay(1000);
        return HttpResponse.json(publicVideo);
      }),
    );
    expect(await loadVideoPage(videoId, { timeoutMs: 50 })).toEqual({ kind: "unavailable" });
  });

  it.each([
    ["without author or stats", { author: undefined, stats: undefined }],
    ["with a handle not in the stored form", { author: { ...author, handle: "../evil" } }],
    ["with someone else's profile", { author: { ...author, user_id: userId } }],
    ["with stats that are not counts", { stats: { view_count: -1, like_count: "x" } }],
  ])("keeps the video %s, without that part", async (_, change) => {
    gateway({ public: () => HttpResponse.json({ ...publicVideo, ...change }) });
    const page = await loadVideoPage(videoId);
    expect(page.kind).toBe("video");
    const video = page.kind === "video" ? page.video : undefined;
    expect(video?.title).toBe(publicVideo.title);
    if ("author" in change) {
      expect(video).not.toHaveProperty("author");
    }
    if ("stats" in change) {
      expect(video).not.toHaveProperty("stats");
    }
  });

  it("keeps only the fields the page uses", async () => {
    gateway({
      public: () => HttpResponse.json({ ...publicVideo, email: "a@b.c", author: { ...author, email: "a@b.c" } }),
    });
    const page = await loadVideoPage(videoId);
    expect(JSON.stringify(page)).not.toContain("a@b.c");
  });

  it("keeps a title holding HTML and quotes as it is: it is rendered as text", async () => {
    const title = `"><script>alert(1)</script>`;
    gateway({ public: () => HttpResponse.json({ ...publicVideo, title }) });
    const page = await loadVideoPage(videoId);
    expect(page.kind === "video" && page.video.title).toBe(title);
  });
});

describe("loadVideoPage with a cookie but no session store", () => {
  it("shows the guest's view when Redis cannot be reached", async () => {
    request.cookies.set("svp_sid", "d".repeat(43));
    const calls = gateway({});
    expect(await loadVideoPage(videoId)).toMatchObject({ kind: "video", viewerId: null });
    expect(calls.map((call) => call.authorization)).toEqual([null]);
  });
});

describe.skipIf(!testRedisURL)("loadVideoPage with a session on the test Redis", () => {
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

  it("reads GET /videos/{id} with the session's token, keeps liked_by_me, and returns no token", async () => {
    const { tokens } = await logIn();
    const calls = gateway({});
    const page = await loadVideoPage(videoId);
    expect(page).toEqual({
      kind: "video",
      video: { ...publicVideo, stats: ownVideo.stats },
      viewerId: userId,
      loadedAt: expect.any(Number),
    });
    expect(calls).toEqual([
      { path: `/videos/${videoId}`, authorization: `Bearer ${tokens.access_token}`, forwardedFor: "203.0.113.7" },
    ]);
    const text = JSON.stringify(page);
    expect(text).not.toContain(tokens.access_token);
    expect(text).not.toContain(tokens.refresh_token);
    expect(text).not.toContain("eyJ");
  });

  it.each(["UPLOADING", "PROCESSING", "FAILED"])(
    "is not found for a %s video, the author's own included, without asking the public route",
    async (status) => {
      await logIn();
      const calls = gateway({ private: () => HttpResponse.json({ ...ownVideo, author_id: userId, status }) });
      expect(await loadVideoPage(videoId)).toEqual({ kind: "not-found" });
      expect(calls.map((call) => call.path)).toEqual([`/videos/${videoId}`]);
    },
  );

  it.each([
    ["404", () => gatewayProblem(404, "VIDEO_NOT_FOUND"), { kind: "not-found" }],
    [
      "429",
      () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "9" }),
      { kind: "rate-limited", retryAfterSeconds: 9 },
    ],
    ["503", () => gatewayProblem(503, "UNAVAILABLE"), { kind: "unavailable" }],
  ])("answers %s of GET /videos/{id} as %j", async (_, answer, expected) => {
    await logIn();
    gateway({ private: answer });
    expect(await loadVideoPage(videoId)).toEqual(expected);
  });

  it("ends the session and shows the guest's view when the gateway refuses its token, redirecting nowhere", async () => {
    const { sid, tokens } = await logIn();
    const logouts = recordLogouts();
    const calls = gateway({ private: () => gatewayProblem(401, "UNAUTHENTICATED") });
    expect(await loadVideoPage(videoId)).toEqual({
      kind: "video",
      video: guestItem,
      viewerId: null,
      loadedAt: expect.any(Number),
    });
    expect(calls.map((call) => [call.path, call.authorization === null])).toEqual([
      [`/videos/${videoId}`, false],
      [`/public/videos/${videoId}`, true],
    ]);
    expect(await request.services!.store.get(sid)).toBeNull();
    expect(logouts).toEqual([tokens.refresh_token]);
  });

  it("refreshes an expired access token first, as every page does", async () => {
    await logIn(-1000);
    const refreshed = fakeTokens(userId);
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(refreshed))));
    const calls = gateway({});
    expect(await loadVideoPage(videoId)).toMatchObject({ kind: "video", viewerId: userId });
    expect(calls[0]?.authorization).toBe(`Bearer ${refreshed.access_token}`);
  });

  it.each([
    ["an unknown sid", async () => request.cookies.set("svp_sid", "b".repeat(43))],
    [
      "a session whose refresh token is rejected",
      async () => {
        await logIn(-1000);
        server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(401, "INVALID_REFRESH_TOKEN")));
      },
    ],
    [
      "a refresh that is rate limited",
      async () => {
        await logIn(-1000);
        server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(429, "RATE_LIMITED")));
      },
    ],
  ])("shows %s the guest's view, without a redirect to /login", async (_, setUp) => {
    await setUp();
    const calls = gateway({});
    expect(await loadVideoPage(videoId)).toMatchObject({ kind: "video", viewerId: null });
    expect(calls.map((call) => [call.path, call.authorization])).toEqual([[`/public/videos/${videoId}`, null]]);
  });
});

describe("videoMetadata", () => {
  const env = { appOrigin: "http://localhost:3001", mediaOrigin: "http://127.0.0.1:9000" };

  it("has the title, the author, and Open Graph tags of a video", () => {
    expect(videoMetadata(guestItem, env, "Video")).toEqual({
      title: "Chiều Hà Nội",
      description: "Minh Anh (@minhanh)",
      openGraph: {
        type: "video.other",
        title: "Chiều Hà Nội",
        description: "Minh Anh (@minhanh)",
        url: `http://localhost:3001/v/${videoId}`,
        images: [{ url: publicVideo.thumbnail_url }],
        videos: [{ url: publicVideo.playlist_url, type: "application/vnd.apple.mpegurl" }],
      },
      twitter: { card: "summary_large_image" },
    });
  });

  it("drops the description, not keeping the site's, when the author is missing", () => {
    const withoutAuthor: FeedItem = { ...guestItem };
    delete withoutAuthor.author;
    const metadata = videoMetadata(withoutAuthor, env, "Video");
    expect(metadata.description).toBeNull();
    expect(metadata.openGraph?.description).toBeUndefined();
  });

  it("calls an untitled video by the page's name", () => {
    const metadata = videoMetadata({ ...guestItem, title: "" }, env, "Video");
    expect(metadata.title).toBe("Video");
    expect(metadata.openGraph?.title).toBe("Video");
  });

  it.each([
    ["another origin", "https://evil.example/t.jpg", "https://evil.example/m.m3u8"],
    ["another port", "http://127.0.0.1:9001/t.jpg", "http://127.0.0.1:9001/m.m3u8"],
    ["not a URL", "javascript:alert(1)", "data:text/html,x"],
  ])("leaves out media URLs on %s", (_, thumbnail, playlist) => {
    const metadata = videoMetadata({ ...guestItem, thumbnail_url: thumbnail, playlist_url: playlist }, env, "Video");
    expect(metadata.openGraph?.images).toBeUndefined();
    expect(metadata.openGraph?.videos).toBeUndefined();
    expect(JSON.stringify(metadata)).not.toContain(thumbnail);
    expect(JSON.stringify(metadata)).not.toContain(playlist);
  });

  it("keeps HTML and quotes in a title as text, which React escapes in the meta tag Next writes", () => {
    const title = `"><script>alert(1)</script>`;
    const name = `Tên "lạ" <b>`;
    const metadata = videoMetadata({ ...guestItem, title, author: { ...author, display_name: name } }, env, "Video");
    // Not escaped here: escaping twice would show &amp;quot; in link previews.
    expect(metadata.openGraph?.title).toBe(title);
    expect(metadata.description).toBe(`${name} (@minhanh)`);
    // Next renders each value as the content attribute of a React <meta> element.
    const html = renderToStaticMarkup(
      createElement("meta", { property: "og:title", content: metadata.openGraph?.title as string }),
    );
    expect(html).toBe('<meta property="og:title" content="&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;"/>');
  });
});
