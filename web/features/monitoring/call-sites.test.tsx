import { render } from "@testing-library/react";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { ErrorsIntlProvider } from "@/components/shell/errors-intl";
import { RouteError } from "@/components/shell/route-error";
import { handleClientError } from "./reporter";

// Every place that catches an error hands it to handleClientError (reload once on a build skew, else report):
// the body of the error boundaries (app/error.tsx, app/global-error.tsx) and the browser's own listeners
// (instrumentation-client.ts). player-pool.test.tsx covers the hls.js loader.

vi.mock("./reporter", () => ({ handleClientError: vi.fn() }));

beforeAll(async () => {
  await import("@/instrumentation-client");
});

beforeEach(() => {
  vi.mocked(handleClientError).mockClear();
});

describe("error boundary", () => {
  it("hands the error it shows to handleClientError once", () => {
    const error = new TypeError("x is undefined");
    const { rerender } = render(
      <ErrorsIntlProvider locale="en">
        <RouteError error={error} retry={vi.fn()} />
      </ErrorsIntlProvider>,
    );
    rerender(
      <ErrorsIntlProvider locale="en">
        <RouteError error={error} retry={vi.fn()} />
      </ErrorsIntlProvider>,
    );
    expect(handleClientError).toHaveBeenCalledExactlyOnceWith(error);
  });
});

describe("window listeners", () => {
  it("hand an uncaught error to handleClientError", () => {
    const error = new TypeError("x is undefined");
    window.dispatchEvent(new ErrorEvent("error", { error, message: error.message }));
    expect(handleClientError).toHaveBeenCalledExactlyOnceWith(error);
  });

  it("skip an error event without an error object (a cross-origin script's)", () => {
    window.dispatchEvent(new ErrorEvent("error", { message: "Script error." }));
    expect(handleClientError).not.toHaveBeenCalled();
  });

  it("hand an unhandled rejection's reason to handleClientError", () => {
    const reason = Object.assign(new Error("Failed to load chunk /_next/static/chunks/a.js from module 1"), {
      name: "ChunkLoadError",
    });
    window.dispatchEvent(Object.assign(new Event("unhandledrejection"), { reason }));
    expect(handleClientError).toHaveBeenCalledExactlyOnceWith(reason);
  });
});
