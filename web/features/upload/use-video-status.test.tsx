import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { UploadApiError, type Video } from "./api";
import { pollDelayMs, useVideoStatus } from "./use-video-status";

const videoId = "0192f0c1-0000-7000-8000-000000000001";
const processing: Video = {
  video_id: videoId,
  author_id: "0192f0c1-0000-7000-8000-000000000002",
  title: "Clip",
  status: "PROCESSING",
  created_at: "2026-10-22T08:00:00Z",
};

// GET /api/videos/{id}: each poll gets the next answer, the last one from then on.
function videoServer(...answers: (() => Response)[]) {
  const calls: number[] = [];
  server.use(
    http.get(`*/api/videos/${videoId}`, () => {
      calls.push(Date.now());
      const answer = (answers.length > 1 ? answers.shift() : answers[0]) ?? (() => HttpResponse.json(processing));
      return answer();
    }),
  );
  return calls;
}

const withStatus = (status: Video["status"]) => () => HttpResponse.json({ ...processing, status });

function renderStatus() {
  const client = new QueryClient();
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  );
  return renderHook(() => useVideoStatus(processing), { wrapper });
}

let hidden = false;

beforeEach(() => {
  hidden = false;
  vi.spyOn(document, "visibilityState", "get").mockImplementation(() => (hidden ? "hidden" : "visible"));
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "Date"] });
  vi.setSystemTime(0);
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

// Lets answers reach the hook. React Query hands results over on zero-delay timers, which the fake clock runs 1 ms
// later when they are set during a tick, so this moves time on by 1 ms a round: 10 ms in all.
async function flush() {
  for (let round = 0; round < 10; round++) {
    await act(() => vi.advanceTimersByTimeAsync(1));
    await new Promise((resolve) => setImmediate(resolve));
  }
}

// Poll times are checked to within the few ms each flush moves the clock.
const near = (ms: number) => expect.closeTo(ms, -2);

async function advance(ms: number) {
  await act(() => vi.advanceTimersByTimeAsync(ms));
  await flush();
}

describe("pollDelayMs", () => {
  it("starts at 2 s and grows 1.5 times up to 10 s", () => {
    expect([0, 1, 2, 3, 4, 5].map(pollDelayMs)).toEqual([2000, 3000, 4500, 6750, 10_000, 10_000]);
  });
});

describe("useVideoStatus", () => {
  it("shows the answer of completing first and polls 2 s later, then less and less often, until READY", async () => {
    const calls = videoServer(withStatus("PROCESSING"), withStatus("PROCESSING"), withStatus("READY"));
    const { result } = renderStatus();
    expect(result.current.data.status).toBe("PROCESSING");
    await advance(1950);
    expect(calls).toEqual([]);
    await advance(50);
    expect(calls).toEqual([near(2000)]);
    await advance(3000);
    expect(calls).toEqual([near(2000), near(5000)]);
    await advance(4500);
    expect(calls).toEqual([near(2000), near(5000), near(9500)]);
    expect(result.current.data.status).toBe("READY");
    await advance(120_000);
    expect(calls).toHaveLength(3);
  });

  it("stops at FAILED", async () => {
    const calls = videoServer(withStatus("FAILED"));
    const { result } = renderStatus();
    await advance(2000);
    expect(result.current.data.status).toBe("FAILED");
    await advance(120_000);
    expect(calls).toHaveLength(1);
  });

  it("keeps polling after a failed poll", async () => {
    const calls = videoServer(
      () => HttpResponse.json({ code: "UNAVAILABLE" }, { status: 503 }),
      () => HttpResponse.error(),
      withStatus("READY"),
    );
    const { result } = renderStatus();
    await advance(2000);
    await advance(3000);
    await advance(4500);
    expect(calls).toHaveLength(3);
    expect(result.current.data.status).toBe("READY");
  });

  it("waits for Retry-After after a 429", async () => {
    const calls = videoServer(
      () => HttpResponse.json({ code: "RATE_LIMITED" }, { status: 429, headers: { "Retry-After": "20" } }),
      withStatus("READY"),
    );
    renderStatus();
    await advance(2000);
    expect(calls).toHaveLength(1);
    await advance(19_900);
    expect(calls).toHaveLength(1);
    await advance(100);
    expect(calls).toHaveLength(2);
  });

  it("stops on 401 and hands the error over", async () => {
    const calls = videoServer(() => HttpResponse.json({ code: "UNAUTHENTICATED" }, { status: 401 }));
    const { result } = renderStatus();
    await advance(2000);
    expect(result.current.error).toBeInstanceOf(UploadApiError);
    expect((result.current.error as UploadApiError).status).toBe(401);
    await advance(120_000);
    expect(calls).toHaveLength(1);
  });

  it("pauses while the tab is hidden and polls at once when it shows again", async () => {
    const calls = videoServer(withStatus("PROCESSING"));
    renderStatus();
    hidden = true;
    act(() => document.dispatchEvent(new Event("visibilitychange", { bubbles: true })));
    await advance(60_000);
    expect(calls).toEqual([]);
    hidden = false;
    act(() => document.dispatchEvent(new Event("visibilitychange", { bubbles: true })));
    await flush();
    expect(calls).toEqual([near(60_000)]);
  });

  it("stops polling when the page unmounts", async () => {
    const calls = videoServer(withStatus("PROCESSING"));
    const { unmount } = renderStatus();
    await advance(2000);
    expect(calls).toHaveLength(1);
    unmount();
    await advance(120_000);
    expect(calls).toHaveLength(1);
  });
});
