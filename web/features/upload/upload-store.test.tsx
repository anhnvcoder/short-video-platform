import { http, HttpResponse } from "msw";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import type { Video } from "./api";
import { stallTimeoutMs } from "./send-form";
import { FakeXHR } from "./testing/fake-xhr";
import { createUploadStore, type Upload, type UploadStore } from "./upload-store";

const uploadOrigin = "http://127.0.0.1:9000";
const uploadUrl = `${uploadOrigin}/uploads`;
const ids = [1, 2, 3, 4].map((n) => `0192f0c1-0000-7000-8000-${String(n).padStart(12, "0")}`);
// The server's clock; the device's clock is set apart from it in some tests.
const serverNow = Date.parse("2026-10-22T08:00:00Z");
const file = new File([new Uint8Array(1000)], "clip.mp4", { type: "video/mp4" });

const problem = (status: number, code: string, headers: Record<string, string> = {}) =>
  HttpResponse.json(
    { type: "about:blank", title: "", status, detail: "", code },
    { status, headers: { "Content-Type": "application/problem+json", ...headers } },
  );

const fieldsFor = (videoId: string) => ({ key: `uploads/${videoId}`, policy: "cG9saWN5", "x-amz-signature": "c2ln" });

function video(videoId: string, status: Video["status"] = "PROCESSING"): Video {
  return { video_id: videoId, author_id: ids[3] ?? "", title: "Clip", status, created_at: "2026-10-22T08:00:00Z" };
}

type InitAnswer = { lifetimeMs?: number; url?: string } | (() => Response);

// POST /api/videos: each call gets the next answer (the last one from then on) and creates the next video id. A form
// answer carries the server's Date and an expires_at `lifetimeMs` after it (15 minutes by default).
function initServer(...answers: InitAnswer[]) {
  const bodies: unknown[] = [];
  server.use(
    http.post("*/api/videos", async ({ request }) => {
      bodies.push(await request.json());
      const answer = (answers.length > 1 ? answers.shift() : answers[0]) ?? {};
      if (typeof answer === "function") {
        return answer();
      }
      const videoId = ids[bodies.length - 1] ?? "";
      return HttpResponse.json(
        {
          video_id: videoId,
          upload_url: answer.url ?? uploadUrl,
          form_fields: fieldsFor(videoId),
          expires_at: new Date(serverNow + (answer.lifetimeMs ?? 15 * 60_000)).toISOString(),
        },
        { status: 201, headers: { Date: new Date(serverNow).toUTCString() } },
      );
    }),
  );
  return bodies;
}

// POST /api/videos/{id}/complete: each call gets the next answer, the last one from then on.
function completeServer(...answers: (() => Response | Promise<Response>)[]) {
  const calls: string[] = [];
  server.use(
    http.post("*/api/videos/:id/complete", ({ params }) => {
      calls.push(String(params.id));
      const answer = (answers.length > 1 ? answers.shift() : answers[0]) ?? (() => new Response(null));
      return answer();
    }),
  );
  return calls;
}

const accepted = (videoId: string) => () => HttpResponse.json(video(videoId), { status: 202 });

let store: UploadStore;
let random = 1;

beforeEach(() => {
  FakeXHR.reset();
  vi.stubGlobal("XMLHttpRequest", FakeXHR);
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date", "performance"] });
  vi.setSystemTime(serverNow);
  random = 1;
  // With random() = 1 the backoff waits its whole cap: 1 s, 2 s, then 4 s.
  store = createUploadStore({ random: () => random });
});

afterEach(() => {
  for (const upload of store.list()) {
    store.dismiss(upload.key);
  }
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

// Lets requests, answers and promise chains finish without moving fake time.
async function flush() {
  for (let round = 0; round < 20; round++) {
    await vi.advanceTimersByTimeAsync(0);
    await new Promise((resolve) => setImmediate(resolve));
  }
}

async function advance(ms: number) {
  await vi.advanceTimersByTimeAsync(ms);
  await flush();
}

function only(): Upload {
  const [upload] = store.list();
  if (!upload || store.list().length !== 1) {
    throw new Error(`expected one upload, got ${store.list().length}`);
  }
  return upload;
}

function start(title = "Clip") {
  return store.start({ file, title, contentType: "video/mp4", uploadOrigin });
}

function setOnline(online: boolean) {
  vi.spyOn(navigator, "onLine", "get").mockReturnValue(online);
  if (online) {
    window.dispatchEvent(new Event("online"));
  }
}

describe("upload store", () => {
  it("asks for a form, sends every field then the file to upload_url, then completes", async () => {
    const bodies = initServer({});
    const completes = completeServer(accepted(ids[0] ?? ""));
    start("  kept as given  ");
    expect(only().status).toBe("preparing");
    await flush();
    expect(bodies).toEqual([{ title: "  kept as given  ", size_bytes: 1000, content_type: "video/mp4" }]);
    const xhr = FakeXHR.last();
    expect(xhr.url).toBe(uploadUrl);
    expect(xhr.withCredentials).toBe(false);
    expect(xhr.headers).toEqual({});
    expect(xhr.fieldNames()).toEqual(["key", "policy", "x-amz-signature", "file"]);
    expect(xhr.body?.get("file")).toBe(file);
    expect(only()).toMatchObject({ status: "sending", videoId: ids[0], progress: 0 });

    xhr.respond(204);
    await flush();
    expect(completes).toEqual([ids[0]]);
    expect(only()).toMatchObject({ status: "processing", video: { video_id: ids[0], status: "PROCESSING" } });
  });

  it("never exposes the upload URL or the form fields in its state", async () => {
    initServer({});
    start();
    await flush();
    const state = JSON.stringify(store.list());
    expect(state).not.toContain(uploadUrl);
    expect(state).not.toContain("cG9saWN5");
    expect(state).not.toContain("c2ln");
  });

  it("reports progress and the speed over the last second", async () => {
    initServer({});
    start();
    await flush();
    const xhr = FakeXHR.last();
    xhr.progress(0, 2000);
    await advance(1000);
    xhr.progress(500, 2000);
    expect(only().progress).toBe(0.25);
    expect(only().bytesPerSecond).toBe(500);
  });

  it("refuses an upload_url outside UPLOAD_ORIGIN without sending a byte", async () => {
    for (const url of ["https://evil.example/uploads", "http://127.0.0.1:9001/uploads", "not a url"]) {
      initServer({ url });
      const key = start();
      await flush();
      expect(store.list().find((upload) => upload.key === key)).toMatchObject({
        status: "failed",
        failure: "bad-origin",
      });
      store.dismiss(key);
    }
    expect(FakeXHR.instances).toHaveLength(0);
  });

  it("cancels: the request is aborted and nothing is completed", async () => {
    initServer({});
    const completes = completeServer(accepted(ids[0] ?? ""));
    const key = start();
    await flush();
    store.cancel(key);
    await flush();
    expect(FakeXHR.last().aborted).toBe(true);
    expect(only().status).toBe("cancelled");
    await advance(60_000);
    expect(completes).toEqual([]);
    expect(FakeXHR.instances).toHaveLength(1);
  });

  it("retries a network error, a 5xx and a stall with a growing backoff, 3 times, then waits for a retry by hand", async () => {
    initServer({});
    completeServer(accepted(ids[0] ?? ""));
    const key = start();
    await flush();

    FakeXHR.last().fail();
    await flush();
    expect(only()).toMatchObject({ status: "waiting", waitingFor: "backoff", retries: 1 });
    await advance(999);
    expect(FakeXHR.instances).toHaveLength(1);
    await advance(1);
    expect(FakeXHR.instances).toHaveLength(2);
    expect(only()).toMatchObject({ status: "sending", progress: 0 });

    FakeXHR.last().respond(503);
    await flush();
    expect(only().retries).toBe(2);
    await advance(1999);
    expect(FakeXHR.instances).toHaveLength(2);
    await advance(1);
    expect(FakeXHR.instances).toHaveLength(3);

    // Nothing moves for 30 s: a timeout, retried like a network error.
    await advance(stallTimeoutMs);
    expect(FakeXHR.instances[2]?.aborted).toBe(true);
    expect(only().retries).toBe(3);
    await advance(4000);
    expect(FakeXHR.instances).toHaveLength(4);

    FakeXHR.last().respond(500);
    await flush();
    expect(only()).toMatchObject({ status: "failed", failure: "send-failed" });
    await advance(60_000);
    expect(FakeXHR.instances).toHaveLength(4);

    store.retry(key);
    await flush();
    expect(FakeXHR.instances).toHaveLength(5);
    FakeXHR.last().respond(204);
    await flush();
    expect(only().status).toBe("processing");
  });

  it("draws each backoff at random below its cap (full jitter)", async () => {
    initServer({});
    random = 0.25;
    start();
    await flush();
    FakeXHR.last().fail();
    await flush();
    // A quarter of the first cap of 1 s.
    await advance(249);
    expect(FakeXHR.instances).toHaveLength(1);
    await advance(1);
    expect(FakeXHR.instances).toHaveLength(2);
  });

  it("waits for the storage's Retry-After on 429 and 503 SlowDown", async () => {
    initServer({});
    start();
    await flush();
    FakeXHR.last().respond(503, { "Retry-After": "5" });
    await flush();
    await advance(4999);
    expect(FakeXHR.instances).toHaveLength(1);
    await advance(1);
    expect(FakeXHR.instances).toHaveLength(2);
    FakeXHR.last().respond(429, { "Retry-After": "3" });
    await flush();
    await advance(2999);
    expect(FakeXHR.instances).toHaveLength(2);
    await advance(1);
    expect(FakeXHR.instances).toHaveLength(3);
  });

  it("stops on a 4xx of the storage other than 403 and 429", async () => {
    initServer({});
    start();
    await flush();
    FakeXHR.last().respond(400);
    await flush();
    expect(only()).toMatchObject({ status: "failed", failure: "rejected" });
  });

  it("offline, waits for the online event before asking for the form, and that wait uses no retry", async () => {
    const bodies = initServer({});
    setOnline(false);
    start();
    await advance(60_000);
    expect(only()).toMatchObject({ status: "waiting", waitingFor: "online", retries: 0 });
    expect(bodies).toHaveLength(0);
    setOnline(true);
    await flush();
    expect(bodies).toHaveLength(1);
    expect(only()).toMatchObject({ status: "sending", retries: 0 });
  });

  it("a connection lost midway is retried from the start of the file once back online", async () => {
    initServer({});
    start();
    await flush();
    FakeXHR.last().progress(600, 1000);
    setOnline(false);
    FakeXHR.last().fail();
    await advance(1000);
    expect(only()).toMatchObject({ status: "waiting", waitingFor: "online", retries: 1 });
    // The last progress stays on screen while waiting.
    expect(only().progress).toBe(0.6);
    await advance(10 * 60_000);
    expect(FakeXHR.instances).toHaveLength(1);
    setOnline(true);
    await flush();
    expect(FakeXHR.instances).toHaveLength(2);
    expect(only()).toMatchObject({ status: "sending", progress: 0, retries: 1 });
  });

  it("losing the connection more than 3 times stops for a retry by hand", async () => {
    initServer({});
    start();
    await flush();
    for (let attempt = 1; attempt <= 4; attempt++) {
      FakeXHR.last().fail();
      await advance(8000);
    }
    expect(FakeXHR.instances).toHaveLength(4);
    expect(only()).toMatchObject({ status: "failed", failure: "send-failed" });
  });

  it("on 403 asks for a new form, a new video, and sends again; a second 403 stops", async () => {
    const bodies = initServer({});
    start();
    await flush();
    FakeXHR.last().respond(403);
    await flush();
    expect(bodies).toHaveLength(2);
    expect(FakeXHR.instances).toHaveLength(2);
    expect(FakeXHR.last().body?.get("key")).toBe(`uploads/${ids[1]}`);
    expect(only()).toMatchObject({ status: "sending", videoId: ids[1], renewed: true, retries: 0 });

    FakeXHR.last().respond(403);
    await flush();
    expect(only()).toMatchObject({ status: "failed", failure: "expired" });
    expect(bodies).toHaveLength(2);
  });

  describe.each([
    ["ahead of", 15 * 60_000],
    ["behind", -15 * 60_000],
  ])("with the device clock 15 minutes %s the server", (_, skewMs) => {
    beforeEach(() => vi.setSystemTime(serverNow + skewMs));

    it("replaces a form that runs out during the backoff before sending again", async () => {
      // 60.5 s left: sent at once, but under a minute left after the first backoff.
      const bodies = initServer({ lifetimeMs: 60_500 });
      start();
      await flush();
      expect(FakeXHR.instances).toHaveLength(1);
      FakeXHR.last().fail();
      await advance(1000);
      expect(bodies).toHaveLength(2);
      expect(FakeXHR.last().body?.get("key")).toBe(`uploads/${ids[1]}`);
      expect(only()).toMatchObject({ videoId: ids[1], renewed: true });
    });

    it("keeps a form with minutes left, whatever this device's clock says", async () => {
      const bodies = initServer({ lifetimeMs: 15 * 60_000 });
      start();
      await flush();
      FakeXHR.last().fail();
      await advance(1000);
      expect(bodies).toHaveLength(1);
      expect(FakeXHR.instances).toHaveLength(2);
    });
  });

  it("TOO_MANY_UPLOADS stops at once, with no retry and nothing sent", async () => {
    const bodies = initServer(() => problem(429, "TOO_MANY_UPLOADS"));
    start();
    await advance(60_000);
    expect(only()).toMatchObject({ status: "failed", failure: "too-many-uploads" });
    expect(bodies).toHaveLength(1);
    expect(FakeXHR.instances).toHaveLength(0);
  });

  it("a rate limit on the form waits for Retry-After, then asks again", async () => {
    const bodies = initServer(() => problem(429, "RATE_LIMITED", { "Retry-After": "3" }), {});
    start();
    await flush();
    expect(only()).toMatchObject({ status: "waiting", retries: 1 });
    await advance(2999);
    expect(bodies).toHaveLength(1);
    await advance(1);
    expect(bodies).toHaveLength(2);
    expect(FakeXHR.instances).toHaveLength(1);
  });

  it("does not retry a form request that failed on the way: it may have created a video", async () => {
    const bodies = initServer(() => problem(503, "UNAVAILABLE"));
    start();
    await advance(60_000);
    expect(only()).toMatchObject({ status: "failed", failure: "init-failed" });
    expect(bodies).toHaveLength(1);
  });

  it("a refused session (401) at any step ends unauthorized", async () => {
    initServer(() => problem(401, "UNAUTHENTICATED"));
    const first = start();
    await flush();
    expect(store.list().find((upload) => upload.key === first)?.failure).toBe("unauthorized");
    store.dismiss(first);

    initServer({});
    completeServer(() => problem(401, "UNAUTHENTICATED"));
    start();
    await flush();
    FakeXHR.last().respond(204);
    await flush();
    expect(only()).toMatchObject({ status: "failed", failure: "unauthorized" });
  });

  it("retries completing after a network error and a 503 without sending the file again", async () => {
    initServer({});
    const completes = completeServer(
      () => HttpResponse.error(),
      () => problem(503, "UNAVAILABLE"),
      accepted(ids[0] ?? ""),
    );
    start();
    await flush();
    FakeXHR.last().respond(204);
    await flush();
    expect(only()).toMatchObject({ status: "waiting", retries: 1 });
    await advance(1000);
    await advance(2000);
    expect(completes).toEqual([ids[0], ids[0], ids[0]]);
    expect(only().status).toBe("processing");
    expect(FakeXHR.instances).toHaveLength(1);
  });

  it("a retry by hand after completing failed only completes", async () => {
    initServer({});
    const completes = completeServer(() => problem(502, "BAD_GATEWAY"));
    const key = start();
    await flush();
    FakeXHR.last().respond(204);
    await flush();
    await advance(1000);
    await advance(2000);
    await advance(4000);
    expect(only()).toMatchObject({ status: "failed", failure: "complete-failed" });
    expect(completes).toHaveLength(4);
    completeServer(accepted(ids[0] ?? ""));
    store.retry(key);
    await flush();
    expect(only().status).toBe("processing");
    expect(FakeXHR.instances).toHaveLength(1);
  });

  it.each(["UPLOAD_NOT_FOUND", "UPLOAD_MISMATCH", "VIDEO_FAILED"])(
    "completing refused with %s stops with a clear failure, not retried",
    async (code) => {
      initServer({});
      const completes = completeServer(() => problem(400, code));
      start();
      await flush();
      FakeXHR.last().respond(204);
      await advance(60_000);
      expect(only()).toMatchObject({ status: "failed", failure: "mismatch" });
      expect(completes).toHaveLength(1);
    },
  );

  it("cancelling while completing aborts that request and sends no other", async () => {
    initServer({});
    const completes = completeServer(() => new Promise<Response>(() => {}));
    const key = start();
    await flush();
    FakeXHR.last().respond(204);
    await flush();
    expect(only().status).toBe("completing");
    store.cancel(key);
    await advance(60_000);
    expect(only().status).toBe("cancelled");
    expect(completes).toHaveLength(1);
  });

  it("cancelling during a backoff ends the wait and sends nothing more", async () => {
    initServer({});
    const key = start();
    await flush();
    FakeXHR.last().fail();
    await flush();
    store.cancel(key);
    await advance(60_000);
    expect(only().status).toBe("cancelled");
    expect(FakeXHR.instances).toHaveLength(1);
  });

  it("keeps two uploads of the same tab apart", async () => {
    initServer({});
    completeServer(accepted(ids[1] ?? ""));
    const first = start("First");
    await flush();
    const second = start("Second");
    await flush();
    const [a, b] = FakeXHR.instances;
    a?.progress(250, 1000);
    b?.respond(204);
    await flush();
    const byKey = Object.fromEntries(store.list().map((upload) => [upload.key, upload]));
    expect(byKey[first]).toMatchObject({ title: "First", status: "sending", progress: 0.25, videoId: ids[0] });
    expect(byKey[second]).toMatchObject({ title: "Second", status: "processing", videoId: ids[1] });
  });

  it("tells subscribers about every change, with a new list each time", async () => {
    initServer({});
    const listener = vi.fn();
    store.subscribe(listener);
    const before = store.list();
    start();
    expect(listener).toHaveBeenCalled();
    expect(store.list()).not.toBe(before);
    const same = store.list();
    expect(store.list()).toBe(same);
  });

  it("asks to confirm leaving the page while an upload runs, and no longer once it is up", async () => {
    initServer({});
    completeServer(accepted(ids[0] ?? ""));
    const leave = () => {
      const event = new Event("beforeunload", { cancelable: true });
      window.dispatchEvent(event);
      return event.defaultPrevented;
    };
    expect(leave()).toBe(false);
    start();
    await flush();
    expect(leave()).toBe(true);
    FakeXHR.last().respond(204);
    await flush();
    expect(only().status).toBe("processing");
    expect(leave()).toBe(false);
  });

  it("dismiss forgets an upload and aborts it", async () => {
    initServer({});
    const key = start();
    await flush();
    store.dismiss(key);
    await flush();
    expect(store.list()).toEqual([]);
    expect(FakeXHR.last().aborted).toBe(true);
  });
});
