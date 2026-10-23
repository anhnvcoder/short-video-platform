import { http, HttpResponse } from "msw";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";

// The reporter keeps per-page state (count, duplicates, off); each test loads a fresh copy, as a new page would.
async function loadReporter() {
  vi.resetModules();
  return import("./reporter");
}

interface Received {
  body: Record<string, unknown>;
  contentType: string | null;
}

// Answers POST /monitoring with `status` and records what arrived.
function monitoring(status = 202): Received[] {
  const received: Received[] = [];
  server.use(
    http.post(`${location.origin}/monitoring`, async ({ request }) => {
      received.push({
        body: JSON.parse(await request.text()) as Record<string, unknown>,
        contentType: request.headers.get("content-type"),
      });
      return new HttpResponse(null, { status });
    }),
  );
  return received;
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 10));

function errorAt(message: string, line = 1): Error {
  const error = new TypeError(message);
  error.stack = `TypeError: ${message}\n    at f (${location.origin}/_next/static/chunks/a.js?dpl=dev-1:${line}:5)`;
  return error;
}

const reload = vi.fn();

beforeEach(() => {
  sessionStorage.clear();
  reload.mockReset();
  vi.stubGlobal("location", { ...location, reload });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  delete (globalThis as { _debugIds?: unknown })._debugIds;
});

describe("reportClientError", () => {
  it("posts a small text/plain report with the path only, without credentials", async () => {
    const received = monitoring();
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const { reportClientError } = await loadReporter();
    const chunk = `${location.origin}/_next/static/chunks/a.js`;
    (globalThis as { _debugIds?: Record<string, string> })._debugIds = {
      [`Error\n    at ${chunk}?dpl=dev-1:1:1`]: "8f1c2a4e-5b6d-4e7f-9a0b-1c2d3e4f5a6b",
      [`Error\n    at ${location.origin}/_next/static/chunks/other.js:1:1`]: "0f1c2a4e-5b6d-4e7f-9a0b-1c2d3e4f5a6b",
    };
    const error = errorAt("x is undefined");
    reportClientError(error);
    await settle();
    expect(received).toEqual([
      {
        body: {
          name: "TypeError",
          message: "x is undefined",
          stack: error.stack,
          path: location.pathname,
          // Only the chunks in this error's stack.
          debug_ids: { [chunk]: "8f1c2a4e-5b6d-4e7f-9a0b-1c2d3e4f5a6b" },
        },
        contentType: "text/plain",
      },
    ]);
    // MSW rebuilds the request, so what fetch was asked for is read from the call.
    expect(fetchSpy).toHaveBeenCalledWith(
      `${location.origin}/monitoring`,
      expect.objectContaining({ method: "POST", keepalive: true, credentials: "omit" }),
    );
  });

  it("cuts long fields to what /monitoring accepts", async () => {
    const received = monitoring();
    const { reportClientError } = await loadReporter();
    const error = new Error("m".repeat(5_000));
    error.name = "N".repeat(500);
    error.stack = "s".repeat(20_000);
    reportClientError(error);
    await settle();
    const body = received[0]?.body;
    expect([body?.name, body?.message, body?.stack].map((value) => (value as string).length)).toEqual([
      200, 1_000, 16_000,
    ]);
  });

  it("reports a thrown value that is not an Error", async () => {
    const received = monitoring();
    const { reportClientError } = await loadReporter();
    reportClientError("boom");
    await settle();
    expect(received[0]?.body).toMatchObject({ name: "Error", message: "boom", stack: "", debug_ids: {} });
  });

  it("sends the same error from the same place once", async () => {
    const received = monitoring();
    const { reportClientError } = await loadReporter();
    reportClientError(errorAt("x is undefined"));
    reportClientError(errorAt("x is undefined"));
    reportClientError(errorAt("x is undefined", 2));
    await settle();
    expect(received).toHaveLength(2);
  });

  it("sends at most 10 reports per page", async () => {
    const received = monitoring();
    const { reportClientError } = await loadReporter();
    for (let i = 0; i < 15; i++) {
      reportClientError(errorAt(`error ${i}`));
    }
    await settle();
    expect(received).toHaveLength(10);
  });

  it("stops for the rest of the page once the server says reporting is off", async () => {
    const received = monitoring(404);
    const { reportClientError } = await loadReporter();
    reportClientError(errorAt("first"));
    await settle();
    reportClientError(errorAt("second"));
    await settle();
    expect(received).toHaveLength(1);
  });

  it("never retries a report the server refused or could not take", async () => {
    const received = monitoring(503);
    const { reportClientError } = await loadReporter();
    reportClientError(errorAt("first"));
    await settle();
    expect(received).toHaveLength(1);
  });

  it("leaves a server error with a digest to the server, which reported it", async () => {
    const received = monitoring();
    const { reportClientError } = await loadReporter();
    reportClientError(Object.assign(new Error("An error occurred in the Server Components render."), { digest: "1" }));
    await settle();
    expect(received).toHaveLength(0);
  });
});

describe("handleClientError", () => {
  function chunkLoadError(): Error {
    return Object.assign(new Error("Failed to load chunk /_next/static/chunks/hls.js from module 7: 404"), {
      name: "ChunkLoadError",
    });
  }

  it("reloads once for a chunk of another build, without a report", async () => {
    const received = monitoring();
    const { handleClientError } = await loadReporter();
    handleClientError(chunkLoadError());
    await settle();
    expect(reload).toHaveBeenCalledOnce();
    expect(received).toHaveLength(0);
  });

  it("reports the chunk error once this build has reloaded already", async () => {
    sessionStorage.setItem("svp:skew-reload:dev", "1");
    const received = monitoring();
    const { handleClientError } = await loadReporter();
    handleClientError(chunkLoadError());
    await settle();
    expect(reload).not.toHaveBeenCalled();
    expect(received[0]?.body).toMatchObject({ name: "ChunkLoadError" });
  });

  it("reports any other error", async () => {
    const received = monitoring();
    const { handleClientError } = await loadReporter();
    handleClientError(errorAt("x is undefined"));
    await settle();
    expect(reload).not.toHaveBeenCalled();
    expect(received).toHaveLength(1);
  });
});
