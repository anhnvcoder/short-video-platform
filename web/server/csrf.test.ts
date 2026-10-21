import { describe, expect, it } from "vitest";
import { passesCsrfCheck } from "./csrf";

const appOrigin = "http://localhost:3001";

function check(method: string, headers: Record<string, string>): boolean {
  return passesCsrfCheck(method, new Headers(headers), appOrigin);
}

describe("passesCsrfCheck", () => {
  it.each(["POST", "PUT", "DELETE", "PATCH"])("lets a same-origin %s through", (method) => {
    expect(check(method, { "sec-fetch-site": "same-origin", origin: appOrigin })).toBe(true);
  });

  it.each(["same-site", "cross-site", "none"])("refuses a POST with Sec-Fetch-Site: %s", (site) => {
    expect(check("POST", { "sec-fetch-site": site, origin: appOrigin })).toBe(false);
  });

  it("without Fetch Metadata takes only the app's exact origin", () => {
    expect(check("POST", { origin: appOrigin })).toBe(true);
    expect(check("POST", { origin: "null" })).toBe(false);
    expect(check("POST", { origin: "http://127.0.0.1:3001" })).toBe(false);
    expect(check("POST", { origin: "http://localhost:3002" })).toBe(false);
    expect(check("POST", { origin: `${appOrigin}.evil.example` })).toBe(false);
  });

  it("refuses an unsafe request with neither header", () => {
    expect(check("POST", {})).toBe(false);
    expect(check("OPTIONS", {})).toBe(false);
  });

  it.each(["GET", "HEAD"])("never blocks %s", (method) => {
    expect(check(method, {})).toBe(true);
    expect(check(method, { "sec-fetch-site": "cross-site", origin: "null" })).toBe(true);
  });
});
