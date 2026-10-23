import { UnrecognizedActionError } from "next/dist/client/components/unrecognized-action-error";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { reloadOnceOnSkew } from "./skew-reload";

// What Turbopack's runtime throws for a chunk it could not load.
function chunkLoadError(): Error {
  const error = new Error("Failed to load chunk /_next/static/chunks/0khh50nt3ldfz.js from module 4210: 404");
  error.name = "ChunkLoadError";
  return error;
}

const key = "svp:skew-reload:dev";
const reload = vi.fn();

beforeEach(() => {
  sessionStorage.clear();
  reload.mockReset();
  vi.stubGlobal("location", { ...location, reload });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("reloadOnceOnSkew", () => {
  it.each([
    ["a chunk that failed to load", chunkLoadError],
    ["a Server Action of another build", () => new UnrecognizedActionError('Server Action "7f0a" was not found')],
  ])("reloads the page once for %s", (_case, makeError) => {
    expect(reloadOnceOnSkew(makeError())).toBe(true);
    expect(reload).toHaveBeenCalledOnce();
    expect(sessionStorage.getItem(key)).toBe("1");
  });

  it.each([
    ["a chunk that failed to load", chunkLoadError],
    ["a Server Action of another build", () => new UnrecognizedActionError("not found")],
  ])("does not reload again for %s once this build has reloaded", (_case, makeError) => {
    sessionStorage.setItem(key, "1");
    expect(reloadOnceOnSkew(makeError())).toBe(false);
    expect(reload).not.toHaveBeenCalled();
  });

  it("stops after one reload when the chunk is really gone", () => {
    expect(reloadOnceOnSkew(chunkLoadError())).toBe(true);
    expect(reloadOnceOnSkew(chunkLoadError())).toBe(false);
    expect(reload).toHaveBeenCalledOnce();
  });

  it.each<[string, unknown]>([
    ["a TypeError", new TypeError("x is undefined")],
    ["an error that only borrows the name", Object.assign(new Error("boom"), { name: "ChunkLoadError" })],
    ["an error named like Next's but not Next's", Object.assign(new Error("x"), { name: "UnrecognizedActionError" })],
    ["a string", "Failed to load chunk"],
    ["nothing", undefined],
  ])("leaves %s to the caller", (_case, error) => {
    expect(reloadOnceOnSkew(error)).toBe(false);
    expect(reload).not.toHaveBeenCalled();
    expect(sessionStorage.getItem(key)).toBeNull();
  });

  it("does not reload when sessionStorage cannot hold the guard", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("quota", "QuotaExceededError");
    });
    expect(reloadOnceOnSkew(chunkLoadError())).toBe(false);
    expect(reload).not.toHaveBeenCalled();
  });
});
