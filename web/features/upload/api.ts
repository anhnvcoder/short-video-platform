import createClient from "openapi-fetch";
import { retryAfterSeconds } from "@/features/feed/api";
import type { components, paths } from "@/gen/api";

// Calls of the upload page to the web server's /api/* proxy (server/api-proxy.ts), same origin with the session
// cookie. The file itself never goes through here: it goes from the browser to the storage (send-form.ts).

export type Video = components["schemas"]["Video"];

// A refused call. `code` is the gateway's reason (TOO_MANY_UPLOADS, UPLOAD_MISMATCH, ...); `retryAfterSeconds` is set
// on 429. The message holds the status only: never a URL or a form field.
export class UploadApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string | undefined,
    readonly retryAfterSeconds?: number,
  ) {
    super(`the API answered ${status}`);
    this.name = "UploadApiError";
  }
}

// A presigned POST to the storage (docs/adr/0018-web-profiles-public-video-upload.md, section 8). `uploadUrl` and
// `fields` are a 15-minute credential: they stay in memory and never reach a log, a message or storage of the browser.
export interface UploadForm {
  videoId: string;
  uploadUrl: string;
  fields: Record<string, string>;
  // How long the form was still valid when the answer left the server: `expires_at` minus the answer's Date header,
  // both from server clocks, so a wrong clock on this device does not matter. The caller counts it down from receipt.
  lifetimeMs: number;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function codeOf(body: unknown): string | undefined {
  return typeof body === "object" && body !== null && "code" in body && typeof body.code === "string"
    ? body.code
    : undefined;
}

function apiError(response: Response, body: unknown): UploadApiError {
  return new UploadApiError(
    response.status,
    codeOf(body),
    response.status === 429 ? retryAfterSeconds(response) : undefined,
  );
}

// The base URL is absolute because the client may build a Request outside a document (tests); it is still this origin.
function client() {
  return createClient<paths>({ baseUrl: `${window.location.origin}/api` });
}

// Creates a video in UPLOADING and returns its upload form. Not idempotent: every call opens one of the user's 3
// upload slots. A network failure rejects with the fetch error.
export async function initUpload(
  input: { title: string; sizeBytes: number; contentType: string },
  signal: AbortSignal,
): Promise<UploadForm> {
  const { data, error, response } = await client().POST("/videos", {
    body: { title: input.title, size_bytes: input.sizeBytes, content_type: input.contentType },
    signal,
  });
  if (!response.ok || !data) {
    throw apiError(response, error);
  }
  // The id goes into API paths and links.
  if (!uuid.test(data.video_id)) {
    throw new UploadApiError(502, "BAD_RESPONSE");
  }
  // The web server's Date header (Node sets one on every answer). Without it, this device's clock is the only one.
  const serverNow = Date.parse(response.headers.get("date") ?? "");
  const lifetimeMs = Date.parse(data.expires_at) - (Number.isNaN(serverNow) ? Date.now() : serverNow);
  return { videoId: data.video_id, uploadUrl: data.upload_url, fields: data.form_fields, lifetimeMs };
}

// Moves the uploaded video to PROCESSING. Idempotent, so a failure can be retried.
export async function completeUpload(videoId: string, signal: AbortSignal): Promise<Video> {
  const { data, error, response } = await client().POST("/videos/{video_id}/complete", {
    params: { path: { video_id: videoId } },
    signal,
  });
  if (!response.ok || !data) {
    throw apiError(response, error);
  }
  return data;
}

export async function fetchVideo(videoId: string, signal: AbortSignal): Promise<Video> {
  const { data, error, response } = await client().GET("/videos/{video_id}", {
    params: { path: { video_id: videoId } },
    signal,
  });
  if (!response.ok || !data) {
    throw apiError(response, error);
  }
  return data;
}
