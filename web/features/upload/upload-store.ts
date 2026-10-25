import { useSyncExternalStore } from "react";
import { completeUpload, initUpload, UploadApiError, type UploadForm, type Video } from "./api";
import { sendForm } from "./send-form";

// The uploads of this browser tab. They run here rather
// than in the upload page, so an upload goes on while the user moves to another page of the app, and any page can show
// them (useUploads). Memory only: nothing goes to localStorage, and the upload form never leaves this module.

export type UploadStatus =
  // Asking the gateway for the upload form.
  | "preparing"
  // Sending the file to the storage.
  | "sending"
  // Between two attempts: a backoff, a Retry-After, or offline (`waitingFor`).
  | "waiting"
  // The file is up; asking the gateway to start processing.
  | "completing"
  // Processing started (`video`); the upload itself is over.
  | "processing"
  // Stopped on `failure`.
  | "failed"
  | "cancelled";

export type UploadFailure =
  // 429 TOO_MANY_UPLOADS: the user already has 3 forms open; not retried.
  | "too-many-uploads"
  // 429 RATE_LIMITED from the gateway after every retry.
  | "rate-limited"
  // The session is gone: the page sends the user to log in.
  | "unauthorized"
  // The form could not be had (network, 5xx, 4xx). Not retried by itself: a request lost on the way may have created
  // a video anyway, and each one takes one of the user's 3 upload slots.
  | "init-failed"
  // upload_url is not on UPLOAD_ORIGIN: nothing was sent.
  | "bad-origin"
  // The storage refused a renewed form too (403).
  | "expired"
  // The storage refused the file (4xx other than 403 and 429).
  | "rejected"
  // The file could not be sent within the retries; retry() sends it again.
  | "send-failed"
  // The file is up but completing failed within the retries; retry() completes it without sending the file again.
  | "complete-failed"
  // Completing found the stored file missing or different (UPLOAD_NOT_FOUND, UPLOAD_MISMATCH, VIDEO_FAILED).
  | "mismatch";

// Failures retry() resumes; any other one needs a new upload (start()).
export const resumableFailures: ReadonlySet<UploadFailure> = new Set(["send-failed", "complete-failed"]);

// Statuses during which leaving the page loses the upload.
const busyStatuses: ReadonlySet<UploadStatus> = new Set(["preparing", "sending", "waiting", "completing"]);

export interface Upload {
  // Local id of the upload; the video id changes when an expired form is replaced.
  readonly key: string;
  // The video being uploaded, once the gateway created it.
  readonly videoId: string | null;
  readonly fileName: string;
  readonly title: string;
  readonly sizeBytes: number;
  readonly status: UploadStatus;
  // Share of the file sent in the current attempt, 0 to 1. A new attempt starts again from 0: a presigned POST does
  // not resume.
  readonly progress: number;
  // Measured over about the last second; null until measured.
  readonly bytesPerSecond: number | null;
  // Automatic retries of the current step so far, at most maxRetries.
  readonly retries: number;
  readonly waitingFor: "online" | "backoff" | null;
  // An expired form was replaced by a new one, which is a new video.
  readonly renewed: boolean;
  readonly failure: UploadFailure | null;
  // The video as completing returned it.
  readonly video: Video | null;
}

export interface StartInput {
  file: File;
  // Already trimmed and checked.
  title: string;
  contentType: string;
  // UPLOAD_ORIGIN of the web server: the file goes only to an upload_url on this origin.
  uploadOrigin: string;
}

export interface UploadStore {
  subscribe(listener: () => void): () => void;
  // The same array until something changes, as useSyncExternalStore needs.
  list(): readonly Upload[];
  // Starts an upload and returns its key.
  start(input: StartInput): string;
  // Stops an upload that is still running or waiting for a retry by hand. The video stays in UPLOADING on the server
  // and keeps one of the 3 upload slots until its form expires.
  cancel(key: string): void;
  // Resumes an upload stopped on a resumable failure.
  retry(key: string): void;
  // Forgets an upload, cancelling it first if it runs.
  dismiss(key: string): void;
}

export interface UploadDeps {
  // Monotonic clock in ms.
  now(): number;
  // In [0, 1), for the jitter of the backoff.
  random(): number;
}

// Automatic retries of one step: 4 attempts in all.
export const maxRetries = 3;
const maxBackoffMs = 8000;
// A form with less than this left is replaced before an attempt instead of failing halfway through the file.
const renewBeforeMs = 60_000;
const speedWindowMs = 1000;

type Attempt<T> = { kind: "done"; value: T } | { kind: "again" } | { kind: "retry"; afterMs?: number };

interface HeldForm {
  value: UploadForm;
  // When it expires on the monotonic clock.
  deadline: number;
  // Sent at least once. A form is always tried once, however short its life looks: a server answer without a usable
  // Date header leaves only this device's clock, which may be wrong by minutes, and the storage has the final word.
  used: boolean;
}

interface Job {
  upload: Upload;
  file: File;
  contentType: string;
  uploadOrigin: string;
  // Where run() goes on from.
  stage: "init" | "send" | "complete";
  form: HeldForm | null;
  controller: AbortController;
  speed: { at: number; loaded: number } | null;
}

class Cancelled extends Error {
  constructor() {
    super("the upload was cancelled");
  }
}

class Failed extends Error {
  constructor(readonly failure: UploadFailure) {
    super(`the upload failed: ${failure}`);
  }
}

function originOf(url: string): string | null {
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new Cancelled());
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(new Cancelled());
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function waitOnline(signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      window.removeEventListener("online", onOnline);
      signal.removeEventListener("abort", onAbort);
    };
    const onOnline = () => {
      cleanup();
      resolve();
    };
    const onAbort = () => {
      cleanup();
      reject(new Cancelled());
    };
    if (signal.aborted) {
      reject(new Cancelled());
      return;
    }
    window.addEventListener("online", onOnline);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function onBeforeUnload(event: BeforeUnloadEvent) {
  // Asks the browser to confirm leaving: the upload would be lost.
  event.preventDefault();
}

export function createUploadStore(deps: Partial<UploadDeps> = {}): UploadStore {
  // Looked up at each call, so a test's fake clock applies.
  const now = deps.now ?? (() => performance.now());
  const random = deps.random ?? (() => Math.random());
  const jobs = new Map<string, Job>();
  const listeners = new Set<() => void>();
  let snapshot: readonly Upload[] = [];
  let lastKey = 0;
  let guardingUnload = false;

  function publish() {
    snapshot = [...jobs.values()].map((job) => job.upload);
    const busy = snapshot.some((upload) => busyStatuses.has(upload.status));
    if (busy !== guardingUnload) {
      guardingUnload = busy;
      if (busy) {
        window.addEventListener("beforeunload", onBeforeUnload);
      } else {
        window.removeEventListener("beforeunload", onBeforeUnload);
      }
    }
    for (const listener of listeners) {
      listener();
    }
  }

  function update(job: Job, patch: Partial<Upload>) {
    // A dismissed upload that is still unwinding changes nothing.
    if (jobs.get(job.upload.key) !== job) {
      return;
    }
    job.upload = { ...job.upload, ...patch };
    publish();
  }

  // Runs `attempt` until it is done. A retry waits for Retry-After when the server gave one, else a full-jitter
  // exponential backoff (a random wait up to 1 s, 2 s, 4 s, at most 8 s), so many clients failing together do not come
  // back together. Offline, it first waits for the browser to be online again, which does not use up a retry.
  async function attempts<T>(job: Job, exhausted: UploadFailure, attempt: () => Promise<Attempt<T>>): Promise<T> {
    const signal = job.controller.signal;
    let retries = 0;
    for (;;) {
      if (!navigator.onLine) {
        update(job, { status: "waiting", waitingFor: "online", bytesPerSecond: null });
        await waitOnline(signal);
      }
      const result = await attempt();
      if (result.kind === "done") {
        return result.value;
      }
      if (result.kind === "again") {
        continue;
      }
      if (retries >= maxRetries) {
        throw new Failed(exhausted);
      }
      const backoff = random() * Math.min(maxBackoffMs, 1000 * 2 ** retries);
      retries += 1;
      update(job, { status: "waiting", waitingFor: "backoff", retries, bytesPerSecond: null });
      await sleep(result.afterMs ?? backoff, signal);
    }
  }

  // Asks for an upload form, which creates a video. Only a rate limit is retried by itself: the gateway refused the
  // request, so no video was created.
  async function obtainForm(job: Job): Promise<void> {
    const signal = job.controller.signal;
    const renewing = job.form !== null;
    const form = await attempts(job, "rate-limited", async (): Promise<Attempt<UploadForm>> => {
      update(job, { status: renewing ? "sending" : "preparing", waitingFor: null });
      try {
        const value = await initUpload(
          { title: job.upload.title, sizeBytes: job.file.size, contentType: job.contentType },
          signal,
        );
        return { kind: "done", value };
      } catch (error) {
        if (signal.aborted) {
          throw new Cancelled();
        }
        if (error instanceof UploadApiError) {
          if (error.status === 401) {
            throw new Failed("unauthorized");
          }
          if (error.status === 429 && error.code === "TOO_MANY_UPLOADS") {
            throw new Failed("too-many-uploads");
          }
          if (error.status === 429) {
            return { kind: "retry", afterMs: (error.retryAfterSeconds ?? 1) * 1000 };
          }
        }
        throw new Failed("init-failed");
      }
    });
    // Checked before a single byte goes out: a tampered answer or a wrong gateway setting must not send the user's
    // file and its credential to another host. The CSP's connect-src is the second guard.
    if (originOf(form.uploadUrl) !== job.uploadOrigin) {
      throw new Failed("bad-origin");
    }
    job.form = { value: form, deadline: now() + form.lifetimeMs, used: false };
    update(job, { videoId: form.videoId, renewed: job.upload.renewed || renewing });
  }

  function heldForm(job: Job): HeldForm {
    if (!job.form) {
      throw new Error("no upload form");
    }
    return job.form;
  }

  function progress(job: Job, loaded: number, total: number) {
    if (total <= 0) {
      return;
    }
    const at = now();
    let bytesPerSecond = job.upload.bytesPerSecond;
    if (job.speed && at - job.speed.at >= speedWindowMs) {
      bytesPerSecond = ((loaded - job.speed.loaded) * 1000) / (at - job.speed.at);
      job.speed = { at, loaded };
    }
    update(job, { progress: Math.min(loaded / total, 1), bytesPerSecond });
  }

  async function sendFile(job: Job): Promise<void> {
    const signal = job.controller.signal;
    let renewedAfterRefusal = false;
    await attempts(job, "send-failed", async (): Promise<Attempt<void>> => {
      // The form may have run out during a backoff, an offline wait, or while the user looked at a failure.
      const held = heldForm(job);
      if (held.used && held.deadline - now() < renewBeforeMs) {
        await obtainForm(job);
      }
      const form = heldForm(job);
      if (signal.aborted) {
        throw new Cancelled();
      }
      form.used = true;
      job.speed = { at: now(), loaded: 0 };
      update(job, { status: "sending", waitingFor: null, progress: 0, bytesPerSecond: null });
      const sending = sendForm(
        form.value.uploadUrl,
        form.value.fields,
        job.file,
        (loaded, total) => progress(job, loaded, total),
        now,
      );
      const abort = () => sending.abort();
      signal.addEventListener("abort", abort, { once: true });
      const outcome = await sending.done;
      signal.removeEventListener("abort", abort);
      switch (outcome.kind) {
        case "sent":
          return { kind: "done", value: undefined };
        case "aborted":
          throw new Cancelled();
        case "network":
        case "timeout":
          return { kind: "retry" };
        case "refused":
          if (outcome.status === 403) {
            // The storage refuses an expired form with 403. A new form fixes that once; a second 403 is something a
            // new form does not fix, and each new form takes one of the user's upload slots.
            if (renewedAfterRefusal) {
              throw new Failed("expired");
            }
            renewedAfterRefusal = true;
            await obtainForm(job);
            return { kind: "again" };
          }
          if (outcome.status === 429 || outcome.status >= 500) {
            const afterMs = outcome.retryAfterSeconds === undefined ? undefined : outcome.retryAfterSeconds * 1000;
            return { kind: "retry", afterMs };
          }
          throw new Failed("rejected");
      }
    });
  }

  // Completing is idempotent, so it is retried without sending the file again.
  async function complete(job: Job): Promise<Video> {
    const signal = job.controller.signal;
    const videoId = heldForm(job).value.videoId;
    return attempts(job, "complete-failed", async (): Promise<Attempt<Video>> => {
      update(job, { status: "completing", waitingFor: null, progress: 1, bytesPerSecond: null });
      try {
        return { kind: "done", value: await completeUpload(videoId, signal) };
      } catch (error) {
        if (signal.aborted) {
          throw new Cancelled();
        }
        if (!(error instanceof UploadApiError)) {
          // No answer: offline or the connection broke.
          return { kind: "retry" };
        }
        if (error.status === 401) {
          throw new Failed("unauthorized");
        }
        if (error.status === 429) {
          return { kind: "retry", afterMs: (error.retryAfterSeconds ?? 1) * 1000 };
        }
        if (error.status >= 500) {
          return { kind: "retry" };
        }
        // UPLOAD_NOT_FOUND, UPLOAD_MISMATCH, VIDEO_FAILED (400) or VIDEO_NOT_FOUND (404): the stored object will not
        // do, and only sending the file again from the start can.
        throw new Failed("mismatch");
      }
    });
  }

  async function run(job: Job) {
    const signal = job.controller.signal;
    try {
      if (job.stage === "init") {
        await obtainForm(job);
        job.stage = "send";
      }
      if (job.stage === "send") {
        await sendFile(job);
        job.stage = "complete";
      }
      const video = await complete(job);
      update(job, { status: "processing", video, waitingFor: null });
    } catch (error) {
      if (signal.aborted) {
        update(job, { status: "cancelled", waitingFor: null, bytesPerSecond: null });
      } else if (error instanceof Failed) {
        update(job, { status: "failed", failure: error.failure, waitingFor: null, bytesPerSecond: null });
      } else {
        // A bug rather than a refusal: stop where it happened, resumable when the file was on its way or up.
        const failure = job.stage === "init" ? "init-failed" : job.stage === "send" ? "send-failed" : "complete-failed";
        update(job, { status: "failed", failure, waitingFor: null, bytesPerSecond: null });
      }
    }
  }

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    list() {
      return snapshot;
    },
    start(input) {
      lastKey += 1;
      const key = `upload-${lastKey}`;
      const job: Job = {
        upload: {
          key,
          videoId: null,
          fileName: input.file.name,
          title: input.title,
          sizeBytes: input.file.size,
          status: "preparing",
          progress: 0,
          bytesPerSecond: null,
          retries: 0,
          waitingFor: null,
          renewed: false,
          failure: null,
          video: null,
        },
        file: input.file,
        contentType: input.contentType,
        uploadOrigin: input.uploadOrigin,
        stage: "init",
        form: null,
        controller: new AbortController(),
        speed: null,
      };
      jobs.set(key, job);
      publish();
      void run(job);
      return key;
    },
    cancel(key) {
      const job = jobs.get(key);
      if (!job) {
        return;
      }
      if (busyStatuses.has(job.upload.status)) {
        job.controller.abort();
      } else if (job.upload.status === "failed") {
        update(job, { status: "cancelled" });
      }
    },
    retry(key) {
      const job = jobs.get(key);
      if (!job || job.upload.status !== "failed" || !job.upload.failure || !resumableFailures.has(job.upload.failure)) {
        return;
      }
      job.controller = new AbortController();
      update(job, { status: job.stage === "complete" ? "completing" : "sending", failure: null, retries: 0 });
      void run(job);
    },
    dismiss(key) {
      const job = jobs.get(key);
      if (!job) {
        return;
      }
      job.controller.abort();
      jobs.delete(key);
      publish();
    },
  };
}

// The store of this tab. On the server it stays empty: uploads start from user events only.
export const uploadStore = createUploadStore();

const noUploads: readonly Upload[] = [];

// Every upload of this tab, oldest first, for pages that show their progress (the upload page, My videos).
export function useUploads(store: UploadStore = uploadStore): readonly Upload[] {
  return useSyncExternalStore(store.subscribe, store.list, () => noUploads);
}
