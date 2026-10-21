import createClient from "openapi-fetch";
import type { components, paths } from "@/gen/api";

// Calls of the feed to the web server's /api/* proxy (server/api-proxy.ts), typed from the gateway's OpenAPI document.
// Same origin with fetch's default credentials, so the session cookie goes along and no token ever reaches the
// browser.

export type FeedKind = "explore" | "following";
export type FeedPage = components["schemas"]["FeedPage"];
export type FeedItem = components["schemas"]["FeedItem"];
export type VideoStats = components["schemas"]["VideoStats"];

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

// Ids go into API paths and React keys: an item whose ids are not canonical UUIDs is dropped rather than used.
function hasValidIds(item: FeedItem): boolean {
  return uuid.test(item.video_id) && uuid.test(item.author_id);
}

export function cleanPage(page: FeedPage): FeedPage {
  return { ...page, items: page.items.filter(hasValidIds) };
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
