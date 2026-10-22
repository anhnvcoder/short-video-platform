import "server-only";
import type { Metadata } from "next";
import { cookies, headers } from "next/headers";
import { cache } from "react";
import { z } from "zod";
import type { FeedItem } from "@/features/feed/api";
import { isMediaUrl } from "@/features/feed/media-url";
import { serverEnv, type ServerEnv } from "./env";
import { gatewayClient, retryAfterSeconds } from "./gateway";
import { bffServices } from "./runtime";
import { sessionCookieName } from "./session";

// Data of the public share page /v/{id} (docs/adr/0018-web-profiles-public-video-upload.md, section 7). A visitor
// without a session cookie gets the public video (GET /public/videos/{id}, no token) and the session store is never
// reached; a visitor with a usable session gets GET /videos/{id} with the session's token, which says whether they like
// the video. The token stays in this module: only the video, checked field by field, is returned.

// Above the gateway's own 3 s per backend call, so the gateway's 504 arrives before this gives up.
const videoTimeoutMs = 4000;

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// The id of the path, lower-case canonical UUID only: anything else is a 404 without a call to the gateway.
export function isVideoId(value: string): boolean {
  return uuid.test(value);
}

export type VideoPage =
  // `viewerId` is the logged-in user, null for a guest. `loadedAt` is when the gateway answered (ms since the epoch),
  // the clock the page counts "2 days ago" from, so the server render and hydration read the same text.
  | { kind: "video"; video: FeedItem; viewerId: string | null; loadedAt: number }
  // Not a video anyone may watch here: no such id, or not READY (the author's own unpublished video included).
  | { kind: "not-found" }
  | { kind: "rate-limited"; retryAfterSeconds: number }
  // Gateway down, timeout, an answer that does not hold a video.
  | { kind: "unavailable" };

const authorSchema = z.object({
  user_id: z.string().regex(uuid),
  // Goes into a /u/<handle> link: the stored form only.
  handle: z.string().regex(/^[a-z][a-z0-9_]{2,29}$/),
  display_name: z.string().min(1),
});

const count = z.number().int().nonnegative();

// Only the fields the page uses, so nothing else the gateway may add one day reaches the browser. Ids go into links
// and API paths, so they must be canonical UUIDs; media URLs are checked against MEDIA_ORIGIN where they are used.
const videoSchema = z.object({
  video_id: z.string().regex(uuid),
  author_id: z.string().regex(uuid),
  title: z.string(),
  duration_ms: z.number(),
  playlist_url: z.string(),
  thumbnail_url: z.string(),
  published_at: z.iso.datetime({ offset: true }),
  // A malformed author or stats object costs only that part, never the video.
  author: authorSchema.optional().catch(undefined),
  stats: z
    .object({ view_count: count, like_count: count, liked_by_me: z.boolean().optional() })
    .optional()
    .catch(undefined),
});

// The video as the feed's components take it. A public video has no liked_by_me: a guest likes nothing.
function toFeedItem(data: unknown, videoId: string): FeedItem | null {
  const parsed = videoSchema.safeParse(data);
  if (!parsed.success || parsed.data.video_id !== videoId) {
    return null;
  }
  const { author, stats, ...video } = parsed.data;
  const item: FeedItem = video;
  // The gateway joins the profile by author_id; one of someone else is not shown as this video's author.
  if (author && author.user_id === video.author_id) {
    item.author = author;
  }
  if (stats) {
    item.stats = {
      view_count: stats.view_count,
      like_count: stats.like_count,
      liked_by_me: stats.liked_by_me ?? false,
    };
  }
  return item;
}

type Answer = { data?: unknown; response: Response };

function fromAnswer({ data, response }: Answer, videoId: string, viewerId: string | null): VideoPage {
  if (response.status === 404) {
    return { kind: "not-found" };
  }
  if (response.status === 429) {
    return { kind: "rate-limited", retryAfterSeconds: retryAfterSeconds(response) };
  }
  if (!response.ok) {
    return { kind: "unavailable" };
  }
  // GET /videos/{id} shows the author their own video in every state; this page shows published videos only, so
  // the same 404 covers it (the author finds their unpublished videos at /me).
  if (viewerId !== null && (data as { status?: unknown } | undefined)?.status !== "READY") {
    return { kind: "not-found" };
  }
  const video = toFeedItem(data, videoId);
  return video ? { kind: "video", video, viewerId, loadedAt: Date.now() } : { kind: "unavailable" };
}

// The usable session and the service that hands it out, or null when the visitor counts as a guest here: no session,
// an expired one, or a session store that cannot be reached or refreshed right now. A public page never sends anyone
// to log in.
async function sessionOf(sid: string, forwardedFor: string | null) {
  try {
    const { access } = await bffServices();
    const result = await access.access(sid, forwardedFor);
    return result.kind === "ok" ? { access, session: result.session } : null;
  } catch {
    return null;
  }
}

async function load(videoId: string, timeoutMs: number): Promise<VideoPage> {
  if (!isVideoId(videoId)) {
    return { kind: "not-found" };
  }
  const env = serverEnv();
  const forwardedFor = (await headers()).get("x-forwarded-for");
  const init = () => ({ params: { path: { video_id: videoId } }, signal: AbortSignal.timeout(timeoutMs) });
  try {
    // The cookie first: a visitor without one is a guest, whatever the session store's state.
    const sid = (await cookies()).get(sessionCookieName(env.secure))?.value;
    const viewer = sid ? await sessionOf(sid, forwardedFor) : null;
    if (sid && viewer) {
      const { access, session } = viewer;
      const answer = await gatewayClient(env.gatewayOrigin, session.access_token, forwardedFor).GET(
        "/videos/{video_id}",
        init(),
      );
      if (answer.response.status !== 401) {
        return fromAnswer(answer, videoId, session.user_id);
      }
      // A token the gateway refuses: the session is of no use. Ending it keeps the login page, which sends a
      // logged-in visitor away, from sending the user elsewhere instead of back here. The page is public, so it then
      // shows the guest's view instead of the login page.
      await access.end(sid, session, forwardedFor).catch(() => {
        // Redis is down: the session stays until its TTL, and the next request tries again.
      });
    }
    const answer = await gatewayClient(env.gatewayOrigin, null, forwardedFor).GET("/public/videos/{video_id}", init());
    return fromAnswer(answer, videoId, null);
  } catch {
    return { kind: "unavailable" };
  }
}

// One call to the gateway per request: generateMetadata and the page both ask, and React's cache hands the second
// the first one's answer.
export const loadVideoPage = cache((videoId: string, options: { timeoutMs?: number } = {}): Promise<VideoPage> =>
  load(videoId, options.timeoutMs ?? videoTimeoutMs),
);

// HLS master playlist (RFC 8216, section 4).
const hlsType = "application/vnd.apple.mpegurl";

// Tags of the page (ADR-0018, section 7). Values are plain text: Next writes them as attributes of <meta>, escaped by
// React, so a title holding HTML or quotes stays text (WEB-1, WEB-18). A media URL off MEDIA_ORIGIN leaves its tag out.
export function videoMetadata(
  video: FeedItem,
  env: Pick<ServerEnv, "appOrigin" | "mediaOrigin">,
  untitled: string,
): Metadata {
  const title = video.title || untitled;
  // null, not undefined: undefined would keep the description of the root layout.
  const description = video.author ? `${video.author.display_name} (@${video.author.handle})` : null;
  const image = isMediaUrl(video.thumbnail_url, env.mediaOrigin) ? video.thumbnail_url : null;
  const playlist = isMediaUrl(video.playlist_url, env.mediaOrigin) ? video.playlist_url : null;
  return {
    title,
    description,
    openGraph: {
      type: "video.other",
      title,
      description: description ?? undefined,
      url: `${env.appOrigin}/v/${video.video_id}`,
      images: image ? [{ url: image }] : undefined,
      videos: playlist ? [{ url: playlist, type: hlsType }] : undefined,
    },
    // A "player" card needs a page made to sit in an iframe, which the CSP (frame-ancestors 'none') forbids.
    twitter: { card: "summary_large_image" },
  };
}
