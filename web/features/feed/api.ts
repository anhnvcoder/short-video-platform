import createClient from "openapi-fetch";
import type { components, paths } from "@/gen/api";

// Calls of the feed to the web server's /api/* proxy (server/api-proxy.ts), typed from the gateway's OpenAPI document.
// Same origin with fetch's default credentials, so the session cookie goes along and no token ever reaches the
// browser.

export type FeedKind = "explore" | "following";
export type FeedPage = components["schemas"]["FeedPage"];
export type FeedItem = components["schemas"]["FeedItem"];
export type VideoStats = components["schemas"]["VideoStats"];
export type Profile = components["schemas"]["Profile"];

// A refused or failed call. `retryAfterSeconds` is set on 429.
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly retryAfterSeconds?: number,
  ) {
    super(`the API answered ${status}`);
    this.name = "ApiError";
  }
}

// Longest Retry-After the feed waits before it tries again by itself.
const maxRetryAfterSeconds = 60;

// Seconds a 429 asks to wait: Retry-After in whole seconds, 1 when it is missing or not a number, at most 60.
export function retryAfterSeconds(response: Response): number {
  const seconds = Number(response.headers.get("retry-after"));
  return Number.isInteger(seconds) && seconds > 0 ? Math.min(seconds, maxRetryAfterSeconds) : 1;
}

function apiError(response: Response): ApiError {
  return response.status === 429 ? new ApiError(429, retryAfterSeconds(response)) : new ApiError(response.status);
}

// The base URL is absolute because the client may build a Request outside a document (tests); it is still this origin.
function client() {
  return createClient<paths>({ baseUrl: `${window.location.origin}/api` });
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const handle = /^[a-z][a-z0-9_]{2,29}$/;

// Ids go into API paths and React keys: an item whose ids are not canonical UUIDs is dropped rather than used.
function hasValidIds(item: FeedItem): boolean {
  return uuid.test(item.video_id) && uuid.test(item.author_id);
}

// The handle goes into a /u/<handle> link: an author not in the stored form, or not the item's author, is left out
// and the item shows the avatar alone, as when user-service did not answer.
function cleanAuthor(author: Profile | undefined, authorId: string): Profile | undefined {
  if (
    !author ||
    author.user_id !== authorId ||
    typeof author.handle !== "string" ||
    !handle.test(author.handle) ||
    typeof author.display_name !== "string" ||
    author.display_name === ""
  ) {
    return undefined;
  }
  return { user_id: author.user_id, handle: author.handle, display_name: author.display_name };
}

// Only the fields of the schema, so nothing else the gateway may add one day is kept in the page or the browser's
// cache.
function cleanItem(item: FeedItem): FeedItem {
  const { video_id, author_id, title, duration_ms, playlist_url, thumbnail_url, published_at, stats } = item;
  const cleaned: FeedItem = { video_id, author_id, title, duration_ms, playlist_url, thumbnail_url, published_at };
  const author = cleanAuthor(item.author, author_id);
  if (author) {
    cleaned.author = author;
  }
  if (stats) {
    cleaned.stats = { view_count: stats.view_count, like_count: stats.like_count, liked_by_me: stats.liked_by_me };
  }
  return cleaned;
}

export function cleanPage(page: FeedPage): FeedPage {
  return { items: page.items.filter(hasValidIds).map(cleanItem), next_cursor: page.next_cursor };
}

// The share link of a video, on the origin the page was opened from.
export function shareUrl(origin: string, videoId: string): string {
  return `${origin}/v/${videoId}`;
}

// Copies the share link of a video to the clipboard. Rejects when the browser refuses (no permission, no Clipboard API
// outside a secure context).
export async function copyShareLink(videoId: string): Promise<void> {
  if (!navigator.clipboard) {
    throw new Error("the Clipboard API is not available");
  }
  await navigator.clipboard.writeText(shareUrl(window.location.origin, videoId));
}

export async function fetchFeedPage(kind: FeedKind, cursor: string, signal?: AbortSignal): Promise<FeedPage> {
  const query = cursor ? { cursor } : {};
  const { data, response } =
    kind === "explore"
      ? await client().GET("/feed/explore", { params: { query }, signal })
      : await client().GET("/feed/following", { params: { query }, signal });
  if (!response.ok || !data) {
    throw apiError(response);
  }
  return cleanPage(data);
}

export async function setLiked(videoId: string, liked: boolean): Promise<void> {
  const params = { params: { path: { video_id: videoId } } };
  const { response } = liked
    ? await client().PUT("/videos/{video_id}/like", params)
    : await client().DELETE("/videos/{video_id}/like", params);
  if (!response.ok) {
    throw apiError(response);
  }
}

export async function setFollowing(userId: string, following: boolean): Promise<void> {
  const params = { params: { path: { user_id: userId } } };
  const { response } = following
    ? await client().PUT("/me/following/{user_id}", params)
    : await client().DELETE("/me/following/{user_id}", params);
  if (!response.ok) {
    throw apiError(response);
  }
}

// One view. A failure is dropped: the view is simply not counted, and retrying could count it twice. Only a refused
// session rejects (ApiError 401), so the page can send the user to log in.
export async function recordView(videoId: string): Promise<void> {
  let response: Response;
  try {
    ({ response } = await client().POST("/videos/{video_id}/views", { params: { path: { video_id: videoId } } }));
  } catch {
    // Offline or aborted.
    return;
  }
  if (response.status === 401) {
    throw new ApiError(401);
  }
}

// Where a refused session sends the user: the login page, back to this page afterwards. A relative path, encoded.
export function loginHref(pathAndSearch: string): string {
  return `/login?next=${encodeURIComponent(pathAndSearch)}`;
}

// Retry policy of feed pages: a rate limit waits for Retry-After, a server or network failure gets two more tries,
// any other refusal (401, 400) none.
export function shouldRetry(failureCount: number, error: unknown): boolean {
  if (error instanceof ApiError) {
    if (error.status === 429) {
      return failureCount < 3;
    }
    return error.status >= 500 && failureCount < 2;
  }
  return failureCount < 2;
}

export function retryDelay(failureCount: number, error: unknown): number {
  if (error instanceof ApiError && error.retryAfterSeconds !== undefined) {
    return error.retryAfterSeconds * 1000;
  }
  return Math.min(1000 * 2 ** failureCount, 8000);
}
