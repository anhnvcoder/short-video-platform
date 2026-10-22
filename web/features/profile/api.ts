import createClient from "openapi-fetch";
import { ApiError, retryAfterSeconds } from "@/features/feed/api";
import type { components, paths } from "@/gen/api";

// Calls of the profile pages (/me, /u/<handle>) to the web server's /api/* proxy (server/api-proxy.ts), same origin
// with the session cookie: no token reaches the browser. The server renders the first page with the same cleaning
// (server/profile-page.ts).

export type VideoStatus = components["schemas"]["Video"]["status"];
type Video = components["schemas"]["Video"];
type VideoPage = components["schemas"]["VideoPage"];

// A video of a profile list: only the fields the lists show, so nothing else the gateway may add one day is kept in
// the page or the browser's cache.
export interface ProfileVideo {
  video_id: string;
  title: string;
  status: VideoStatus;
  created_at: string;
  // Set once READY.
  duration_ms?: number;
  published_at?: string;
  // Checked against MEDIA_ORIGIN where it is shown.
  thumbnail_url?: string;
  // Absent when engagement-service did not answer in time.
  view_count?: number;
}

export interface ProfileVideoPage {
  items: ProfileVideo[];
  next_cursor: string;
}

// The other user's profile as /u/<handle> shows it.
export interface ShownProfile {
  userId: string;
  handle: string;
  displayName: string;
  followedByMe: boolean;
}

// Videos a page asks for: 3 rows of the 3-column grid on a phone, 3 rows of 6 on a wide screen
// (docs/adr/0018-web-profiles-public-video-upload.md, section 4).
export const videoPageSize = 18;

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// A handle as user-service stores it (ADR-0018, section 1).
const handlePattern = /^[a-z][a-z0-9_]{2,29}$/;
const statuses: ReadonlySet<string> = new Set<VideoStatus>(["UPLOADING", "PROCESSING", "READY", "FAILED"]);

export function isHandle(value: string): boolean {
  return handlePattern.test(value);
}

// Only ASCII A-Z is lowered, as user-service does: a Unicode lowering would turn the Kelvin sign into k.
export function lowerHandle(value: string): string {
  return value.replace(/[A-Z]/g, (letter) => letter.toLowerCase());
}

export function profileHref(handle: string): string {
  return `/u/${handle}`;
}

function cleanVideo(video: Video): ProfileVideo {
  const { video_id, title, status, created_at, duration_ms, published_at, thumbnail_url, stats } = video;
  const cleaned: ProfileVideo = { video_id, title: typeof title === "string" ? title : "", status, created_at };
  if (typeof duration_ms === "number") {
    cleaned.duration_ms = duration_ms;
  }
  if (typeof published_at === "string") {
    cleaned.published_at = published_at;
  }
  if (typeof thumbnail_url === "string") {
    cleaned.thumbnail_url = thumbnail_url;
  }
  if (typeof stats?.view_count === "number") {
    cleaned.view_count = stats.view_count;
  }
  return cleaned;
}

// The page as the lists use it. The id goes into a /v/<id> link and React keys, so an item whose id is not a canonical
// UUID, of another author than the list's, or with a status this client does not know is dropped rather than shown.
export function cleanVideoPage(page: VideoPage, authorId: string): ProfileVideoPage {
  const items = Array.isArray(page.items) ? page.items : [];
  return {
    items: items
      .filter(
        (video) =>
          uuid.test(video.video_id) &&
          video.author_id === authorId &&
          statuses.has(video.status) &&
          typeof video.created_at === "string",
      )
      .map(cleanVideo),
    next_cursor: typeof page.next_cursor === "string" ? page.next_cursor : "",
  };
}

function apiError(response: Response): ApiError {
  return response.status === 429 ? new ApiError(429, retryAfterSeconds(response)) : new ApiError(response.status);
}

// The base URL is absolute because the client may build a Request outside a document (tests); it is still this origin.
function client() {
  return createClient<paths>({ baseUrl: `${window.location.origin}/api` });
}

function pageQuery(cursor: string) {
  return cursor ? { page_size: videoPageSize, cursor } : { page_size: videoPageSize };
}

// The caller's own videos in every state; `userId` is the caller, for the cleaning.
export async function fetchMyVideos(userId: string, cursor: string, signal?: AbortSignal): Promise<ProfileVideoPage> {
  const { data, response } = await client().GET("/me/videos", { params: { query: pageQuery(cursor) }, signal });
  if (!response.ok || !data) {
    throw apiError(response);
  }
  return cleanVideoPage(data, userId);
}

// Another user's READY videos.
export async function fetchUserVideos(userId: string, cursor: string, signal?: AbortSignal): Promise<ProfileVideoPage> {
  const { data, response } = await client().GET("/users/{user_id}/videos", {
    params: { path: { user_id: userId }, query: pageQuery(cursor) },
    signal,
  });
  if (!response.ok || !data) {
    throw apiError(response);
  }
  return cleanVideoPage(data, userId);
}

// Copies the profile's link, on the origin the page was opened from. Rejects when the browser refuses (no permission,
// no Clipboard API outside a secure context).
export async function copyProfileLink(handle: string): Promise<void> {
  if (!navigator.clipboard) {
    throw new Error("the Clipboard API is not available");
  }
  await navigator.clipboard.writeText(`${window.location.origin}${profileHref(handle)}`);
}
