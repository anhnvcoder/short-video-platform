import type { ReactElement } from "react";
import { createTranslator } from "next-intl";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { rateLimitWait } from "@/components/shell/route-error";
import type { FeedItem } from "@/features/feed/api";
import { messagesFor } from "@/i18n/messages";
import { testEnv } from "@/server/testing/bff";
import type { VideoPage as LoadedPage } from "@/server/video-page";

const loader = vi.hoisted(() => ({ load: vi.fn() }));

vi.mock("@/server/video-page", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/server/video-page")>()),
  loadVideoPage: loader.load,
}));
vi.mock("@/server/env", () => ({ serverEnv: () => testEnv }));
vi.mock("next-intl/server", () => ({
  getLocale: async () => "vi",
  getMessages: async () => messagesFor("vi"),
  getTranslations: async (namespace: string) =>
    createTranslator({ locale: "vi", messages: messagesFor("vi"), namespace: namespace as "share" }),
}));

const { default: VideoPage, generateMetadata } = await import("./page");

const videoId = "0192f0c1-0000-7000-8000-000000000001";
const authorId = "0192f0c1-7a3e-7c4b-9d2e-000000000002";
const video: FeedItem = {
  video_id: videoId,
  author_id: authorId,
  title: "Chiều Hà Nội",
  duration_ms: 42_000,
  playlist_url: `${testEnv.mediaOrigin}/media/hls/1/master.m3u8`,
  thumbnail_url: `${testEnv.mediaOrigin}/media/thumbs/1.jpg`,
  published_at: "2026-10-20T08:00:00Z",
  author: { user_id: authorId, handle: "minhanh", display_name: "Minh Anh" },
  stats: { view_count: 3, like_count: 2, liked_by_me: false },
};
const shown: LoadedPage = { kind: "video", video, viewerId: null, loadedAt: 1_760_000_000_000 };

const params = (id: string) => ({ params: Promise.resolve({ id }) });
const t = messagesFor("vi").share;

async function thrown(run: Promise<unknown>): Promise<unknown> {
  return run.then(
    () => undefined,
    (error: unknown) => error,
  );
}

const digestOf = (error: unknown) => (error as { digest?: string } | undefined)?.digest;

beforeEach(() => {
  loader.load.mockReset();
});

describe("generateMetadata of /v/[id]", () => {
  it("has the video's title and Open Graph tags", async () => {
    loader.load.mockResolvedValue(shown);
    const metadata = await generateMetadata(params(videoId));
    expect(loader.load).toHaveBeenCalledWith(videoId);
    expect(metadata).toMatchObject({
      title: "Chiều Hà Nội",
      description: "Minh Anh (@minhanh)",
      openGraph: {
        type: "video.other",
        url: `${testEnv.appOrigin}/v/${videoId}`,
        images: [{ url: video.thumbnail_url }],
        videos: [{ url: video.playlist_url, type: "application/vnd.apple.mpegurl" }],
      },
      twitter: { card: "summary_large_image" },
    });
  });

  it("is the 404 title for an id that is not a canonical UUID, without loading anything", async () => {
    expect(await generateMetadata(params(videoId.toUpperCase()))).toEqual({ title: t.notFound.title });
    expect(loader.load).not.toHaveBeenCalled();
  });

  it("is the 404 title for a video nobody may watch here", async () => {
    loader.load.mockResolvedValue({ kind: "not-found" });
    expect(await generateMetadata(params(videoId))).toEqual({ title: t.notFound.title });
  });

  it.each<LoadedPage>([{ kind: "rate-limited", retryAfterSeconds: 5 }, { kind: "unavailable" }])(
    "adds nothing for %j: the error page has its own",
    async (page) => {
      loader.load.mockResolvedValue(page);
      expect(await generateMetadata(params(videoId))).toEqual({});
    },
  );
});

describe("/v/[id] page", () => {
  it.each([videoId.toUpperCase(), videoId.replaceAll("-", ""), "..", "x"])(
    "is a 404 for the id %j, without loading anything",
    async (id) => {
      expect(digestOf(await thrown(VideoPage(params(id))))).toBe("NEXT_HTTP_ERROR_FALLBACK;404");
      expect(loader.load).not.toHaveBeenCalled();
    },
  );

  it("is a 404 for a video nobody may watch here", async () => {
    loader.load.mockResolvedValue({ kind: "not-found" });
    expect(digestOf(await thrown(VideoPage(params(videoId))))).toBe("NEXT_HTTP_ERROR_FALLBACK;404");
  });

  it.each([
    [30, 30],
    [0, 1],
    [999_999, 3600],
  ])("on a rate limit of %d s shows the rate limit page counting down %d s", async (retryAfterSeconds, wait) => {
    loader.load.mockResolvedValue({ kind: "rate-limited", retryAfterSeconds });
    const error = await thrown(VideoPage(params(videoId)));
    expect(digestOf(error)).toBe(`SVP_RATE_LIMITED;${wait}`);
    // The digest error.tsx reads.
    expect(rateLimitWait(error)).toBe(wait);
  });

  it("shows the generic error page when the video cannot be loaded", async () => {
    loader.load.mockResolvedValue({ kind: "unavailable" });
    const error = await thrown(VideoPage(params(videoId)));
    expect(error).toBeInstanceOf(Error);
    expect(rateLimitWait(error)).toBeNull();
  });

  it("hands the share screen the video, the viewer and the media origin, with the feed and share messages and its link's spinner label only", async () => {
    loader.load.mockResolvedValue({ ...shown, viewerId: "0192f0c1-7a3e-7c4b-9d2e-000000000001" });
    const element = (await VideoPage(params(videoId))) as ReactElement<{
      messages: Record<string, unknown>;
      children: ReactElement<Record<string, unknown>>;
    }>;
    // A nested provider replaces the root's messages: what is not here, the share screen cannot translate.
    expect(element.props.messages).toEqual({
      feed: messagesFor("vi").feed,
      share: messagesFor("vi").share,
      common: { loading: messagesFor("vi").common.loading },
    });
    expect(element.props.children.props).toEqual({
      video,
      viewerId: "0192f0c1-7a3e-7c4b-9d2e-000000000001",
      mediaOrigin: testEnv.mediaOrigin,
      loadedAt: shown.loadedAt,
      // Published after the gateway's answer in this fixture: a time ahead of the clock reads as just now.
      renderedAgo: messagesFor("vi").feed.justNow,
      appName: "SVP",
    });
  });

  it("writes the video's age counted from when the gateway answered, so the browser hydrates it without formatting", async () => {
    loader.load.mockResolvedValue({ ...shown, loadedAt: Date.parse(video.published_at) + 2 * 24 * 60 * 60 * 1000 });
    const element = (await VideoPage(params(videoId))) as ReactElement<{
      children: ReactElement<Record<string, unknown>>;
    }>;
    expect(element.props.children.props.renderedAgo).toBe("2 ngày trước");
  });
});
