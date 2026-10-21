import { afterAll, afterEach, beforeAll } from "vitest";
import { server } from "@/lib/test/msw-server";

// No test reaches the network: a request without a handler from the test fails it.
beforeAll(() => server.listen({ onUnhandledFrame: "error" }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());

if (typeof document !== "undefined") {
  // Testing Library unmounts after each test only by itself when vitest globals are on; they are off here.
  const { cleanup } = await import("@testing-library/react");
  afterEach(cleanup);
}
