import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sendForm, stallTimeoutMs } from "./send-form";
import { FakeXHR } from "./testing/fake-xhr";

const url = "http://127.0.0.1:9000/uploads";
const fields = { key: "uploads/0192f0c1-0000-7000-8000-000000000001", policy: "cG9saWN5", "x-amz-signature": "abc" };
const file = new File(["video bytes"], "clip.mp4", { type: "video/mp4" });

let clock = 0;
const now = () => clock;

beforeEach(() => {
  clock = 0;
  FakeXHR.reset();
  vi.stubGlobal("XMLHttpRequest", FakeXHR);
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function advance(ms: number) {
  clock += ms;
  await vi.advanceTimersByTimeAsync(ms);
}

describe("sendForm", () => {
  it("posts every form field first and the file last, with no cookie and no header of its own", () => {
    sendForm(url, fields, file, () => {}, now);
    const xhr = FakeXHR.last();
    expect(xhr.method).toBe("POST");
    expect(xhr.url).toBe(url);
    expect(xhr.withCredentials).toBe(false);
    expect(xhr.headers).toEqual({});
    expect(xhr.fieldNames()).toEqual(["key", "policy", "x-amz-signature", "file"]);
    expect(xhr.body?.get("key")).toBe(fields.key);
    expect(xhr.body?.get("file")).toBeInstanceOf(File);
  });

  it("reports progress and resolves sent on 2xx", async () => {
    const onProgress = vi.fn();
    const sending = sendForm(url, fields, file, onProgress, now);
    FakeXHR.last().progress(5, 10);
    expect(onProgress).toHaveBeenCalledWith(5, 10);
    FakeXHR.last().respond(204);
    await expect(sending.done).resolves.toEqual({ kind: "sent" });
  });

  it("resolves refused with the status and a readable Retry-After", async () => {
    const sending = sendForm(url, fields, file, () => {}, now);
    FakeXHR.last().respond(503, { "Retry-After": "7" });
    await expect(sending.done).resolves.toEqual({ kind: "refused", status: 503, retryAfterSeconds: 7 });
  });

  it("resolves network when no answer comes", async () => {
    const sending = sendForm(url, fields, file, () => {}, now);
    FakeXHR.last().fail();
    await expect(sending.done).resolves.toEqual({ kind: "network" });
  });

  it("aborts on request", async () => {
    const sending = sendForm(url, fields, file, () => {}, now);
    sending.abort();
    expect(FakeXHR.last().aborted).toBe(true);
    await expect(sending.done).resolves.toEqual({ kind: "aborted" });
  });

  it("times out after 30 s without progress, counted from the last progress event", async () => {
    const sending = sendForm(url, fields, file, () => {}, now);
    let outcome: unknown = null;
    void sending.done.then((value) => (outcome = value));
    await advance(20_000);
    FakeXHR.last().progress(1, 10);
    await advance(stallTimeoutMs - 1);
    expect(outcome).toBeNull();
    expect(FakeXHR.last().aborted).toBe(false);
    await advance(1);
    expect(FakeXHR.last().aborted).toBe(true);
    expect(outcome).toEqual({ kind: "timeout" });
  });

  it("does not time out an upload that keeps sending, however long it takes", async () => {
    const sending = sendForm(url, fields, file, () => {}, now);
    for (let second = 1; second <= 600; second += 10) {
      await advance(10_000);
      FakeXHR.last().progress(second, 1000);
    }
    expect(FakeXHR.last().aborted).toBe(false);
    FakeXHR.last().respond(204);
    await expect(sending.done).resolves.toEqual({ kind: "sent" });
  });
});
