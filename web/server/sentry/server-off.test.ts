import * as Sentry from "@sentry/nextjs";
import { describe, expect, it } from "vitest";
import { testEnv } from "../testing/bff";
import { startErrorReporting } from "./server";

describe("server error reporting without SENTRY_DSN", () => {
  it("starts no SDK client, so every capture is a no-op", () => {
    startErrorReporting(testEnv);
    expect(Sentry.getClient()).toBeUndefined();
    expect(() =>
      Sentry.captureRequestError(
        new Error("boom"),
        { path: "/", method: "GET", headers: {} },
        { routerKind: "App Router", routePath: "/", routeType: "render" },
      ),
    ).not.toThrow();
  });
});
