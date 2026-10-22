// Checks of a file and a title before anything is sent (docs/adr/0018-web-profiles-public-video-upload.md, section 8).
// They spare the user a doomed upload; they are not the guard: the signed form limits the size and the type, and the
// media worker's ffprobe decides what a video is.

// 500 MiB, the `maximum` of size_bytes in the gateway's OpenAPI document.
export const maxUploadBytes = 524_288_000;
export const maxDurationSeconds = 180;
// Counted in characters (code points) after trimming, as video-service counts them.
export const maxTitleLength = 200;

// Media types for files the browser gives no type, by extension.
const typeByExtension: Record<string, string> = {
  mp4: "video/mp4",
  mov: "video/quicktime",
  webm: "video/webm",
};

export type FileProblem = "not-video" | "empty" | "too-large";

export type FileCheck = { ok: true; contentType: string } | { ok: false; problem: FileProblem };

function contentTypeOf(file: Pick<File, "name" | "type">): string | null {
  const type = file.type.toLowerCase();
  if (type !== "") {
    return type.startsWith("video/") ? type : null;
  }
  const extension = /\.([^.]+)$/.exec(file.name)?.[1]?.toLowerCase() ?? "";
  return typeByExtension[extension] ?? null;
}

export function checkFile(file: Pick<File, "name" | "type" | "size">): FileCheck {
  const contentType = contentTypeOf(file);
  if (contentType === null) {
    return { ok: false, problem: "not-video" };
  }
  if (file.size === 0) {
    return { ok: false, problem: "empty" };
  }
  if (file.size > maxUploadBytes) {
    return { ok: false, problem: "too-large" };
  }
  return { ok: true, contentType };
}

// How long reading the metadata may take before the file is let through unread.
const metadataTimeoutMs = 10_000;

// The duration of a video file in seconds, read by the browser from its metadata, or null when the browser cannot read
// it (a codec it does not decode, such as HEVC on Chromium; a broken file). Null lets the file through: the worker
// decides. The object URL is revoked once the answer is in.
export function readDuration(file: Blob): Promise<number | null> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    let done = false;
    const finish = (seconds: number | null) => {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timer);
      video.removeAttribute("src");
      URL.revokeObjectURL(url);
      resolve(seconds);
    };
    const timer = setTimeout(() => finish(null), metadataTimeoutMs);
    video.preload = "metadata";
    video.muted = true;
    video.addEventListener("loadedmetadata", () =>
      // Some files (a WebM written live) report an infinite duration: unknown, like an unreadable one.
      finish(Number.isFinite(video.duration) && video.duration > 0 ? video.duration : null),
    );
    video.addEventListener("error", () => finish(null));
    video.src = url;
  });
}

export type TitleProblem = "required" | "too-long";

export function titleLength(title: string): number {
  return [...title.trim()].length;
}

export function checkTitle(title: string): TitleProblem | null {
  const length = titleLength(title);
  if (length === 0) {
    return "required";
  }
  return length > maxTitleLength ? "too-long" : null;
}
