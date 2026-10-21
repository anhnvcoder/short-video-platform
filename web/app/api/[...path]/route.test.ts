import { NextRequest } from "next/server";
import { describe, expect, it, vi } from "vitest";

vi.mock("@/server/runtime", () => ({
  bffServices: async () => {
    throw new Error("redis down");
  },
}));

const route = await import("./route");

describe("/api/[...path]", () => {
  it("routes every method through the proxy handler", () => {
    for (const method of ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] as const) {
      expect(route[method]).toBe(route.GET);
    }
  });

  it("answers 503 when the BFF cannot start its services", async () => {
    const response = await route.GET(new NextRequest("http://localhost:3001/api/feed/explore"));
    expect(response.status).toBe(503);
    expect(response.headers.get("content-type")).toBe("application/problem+json");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });
});
