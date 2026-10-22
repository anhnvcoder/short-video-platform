// One attempt to send a file to the storage with a presigned POST (docs/adr/0018-web-profiles-public-video-upload.md,
// section 8). XMLHttpRequest rather than fetch: only it reports upload progress in every browser and can be aborted
// mid-body. The request carries no cookie (withCredentials stays false) and no header of ours: the signed form is the
// whole authorization, and the storage's CORS allows only the web origin.

export type SendOutcome =
  // The storage stored the file (2xx).
  | { kind: "sent" }
  // The storage answered with an error status. `retryAfterSeconds` when it sent a Retry-After the page may read.
  | { kind: "refused"; status: number; retryAfterSeconds?: number }
  // No answer: offline, connection reset, DNS, a CORS refusal.
  | { kind: "network" }
  // No progress for `stallTimeoutMs`.
  | { kind: "timeout" }
  // Aborted by the caller.
  | { kind: "aborted" };

export interface Sending {
  done: Promise<SendOutcome>;
  abort(): void;
}

// An attempt that has sent nothing for this long has stalled. There is no limit on the whole attempt: 500 MiB over a
// slow link takes long and is fine as long as bytes move.
export const stallTimeoutMs = 30_000;

// Longest Retry-After of the storage that is honoured.
const maxRetryAfterSeconds = 60;

function retryAfter(xhr: XMLHttpRequest): number | undefined {
  const seconds = Number(xhr.getResponseHeader("retry-after"));
  return Number.isInteger(seconds) && seconds > 0 ? Math.min(seconds, maxRetryAfterSeconds) : undefined;
}

// Sends every form field, then the file as the last field, as the storage requires. `onProgress` gets the bytes of
// the request body sent so far and its total. `now` is a monotonic clock in ms (performance.now): a background tab
// fires timers late, so the stall check reads the time since the last progress rather than counting on the timer.
export function sendForm(
  url: string,
  fields: Record<string, string>,
  file: Blob,
  onProgress: (loaded: number, total: number) => void,
  now: () => number,
): Sending {
  const xhr = new XMLHttpRequest();
  const form = new FormData();
  for (const [name, value] of Object.entries(fields)) {
    form.append(name, value);
  }
  form.append("file", file);

  let timedOut = false;
  const done = new Promise<SendOutcome>((resolve) => {
    let settled = false;
    let lastProgress = now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (outcome: SendOutcome) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(outcome);
      }
    };
    const watch = () => {
      const idle = now() - lastProgress;
      if (idle >= stallTimeoutMs) {
        timedOut = true;
        xhr.abort();
        return;
      }
      timer = setTimeout(watch, stallTimeoutMs - idle);
    };

    xhr.upload.addEventListener("progress", (event) => {
      lastProgress = now();
      onProgress(event.loaded, event.lengthComputable ? event.total : 0);
    });
    xhr.addEventListener("load", () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        finish({ kind: "sent" });
      } else {
        finish({ kind: "refused", status: xhr.status, retryAfterSeconds: retryAfter(xhr) });
      }
    });
    xhr.addEventListener("error", () => finish({ kind: "network" }));
    xhr.addEventListener("abort", () => finish(timedOut ? { kind: "timeout" } : { kind: "aborted" }));
    xhr.open("POST", url);
    xhr.send(form);
    timer = setTimeout(watch, stallTimeoutMs);
  });
  return { done, abort: () => xhr.abort() };
}
