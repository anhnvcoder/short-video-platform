import { http, HttpResponse } from "msw";
import { getURLFromRedirectError } from "next/dist/client/components/redirect";
import { isRedirectError } from "next/dist/client/components/redirect-error";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { initialDisplayNameState } from "@/features/profile/display-name";
import { server } from "@/lib/test/msw-server";
import type { BffServices } from "./runtime";
import { accessTokenBody, fakeTokens, gatewayOrigin, gatewayProblem, recordLogouts, testServices } from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

// The action runs outside a Next request here: cookies() and headers() are stand-ins, the services come from the test,
// redirect() is Next's own (it throws an error naming the target), and refresh() is recorded.
const request = vi.hoisted(() => ({
  cookies: new Map<string, string>(),
  headers: new Headers(),
  services: undefined as BffServices | undefined,
  refreshes: 0,
}));

vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: (name: string) => {
      const value = request.cookies.get(name);
      return value === undefined ? undefined : { name, value };
    },
  }),
  headers: async () => request.headers,
}));
vi.mock("next/cache", () => ({
  refresh: () => {
    request.refreshes++;
  },
}));
vi.mock("./runtime", () => ({
  bffServices: async () => {
    if (!request.services) {
      throw new Error("redis down");
    }
    return request.services;
  },
}));
vi.mock("./env", () => ({ serverEnv: () => request.services?.env ?? { secure: false } }));

const { updateDisplayNameAction } = await import("./profile-actions");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const loginTarget = `/login?next=${encodeURIComponent("/me")}`;

function form(name?: string): FormData {
  const data = new FormData();
  if (name !== undefined) {
    data.set("display_name", name);
  }
  return data;
}

const rename = (name?: string) => updateDisplayNameAction(initialDisplayNameState, form(name));

async function redirectTarget(run: Promise<unknown>): Promise<string> {
  const error = await run.then(
    () => undefined,
    (thrown: unknown) => thrown,
  );
  expect(isRedirectError(error)).toBe(true);
  return isRedirectError(error) ? getURLFromRedirectError(error) : "";
}

// Records each PATCH /me and answers it.
function patchServer(answer: (name: string) => Response = (name) => HttpResponse.json(profileWith(name))) {
  const calls: { body: unknown; authorization: string | null; forwardedFor: string | null }[] = [];
  server.use(
    http.patch(`${gatewayOrigin}/me`, async ({ request: call }) => {
      const body = (await call.json()) as { display_name: string };
      calls.push({
        body,
        authorization: call.headers.get("authorization"),
        forwardedFor: call.headers.get("x-forwarded-for"),
      });
      return answer(body.display_name);
    }),
  );
  return calls;
}

const profileWith = (name: string) => ({ user_id: userId, handle: "lanphuong", display_name: name });

beforeEach(() => {
  request.cookies.clear();
  request.headers = new Headers({ "x-forwarded-for": "203.0.113.9" });
  request.services = undefined;
  request.refreshes = 0;
});

describe("updateDisplayNameAction before the session is looked at", () => {
  it.each([
    ["an empty name", "", "REQUIRED"],
    ["a missing field", undefined, "REQUIRED"],
    ["white space only", "  \t \n ", "REQUIRED"],
    ["51 Vietnamese characters", "Phương ".repeat(7) + "Lư", "TOO_LONG"],
    ["a line break inside", "Lan\nPhương", "INVALID_CHARACTERS"],
    ["a tab inside", "Lan\tPhương", "INVALID_CHARACTERS"],
    ["NUL", "Lan\u0000", "INVALID_CHARACTERS"],
    ["U+0085", "Lan\u0085Phương", "INVALID_CHARACTERS"],
    ["U+2028", "Lan Phương", "INVALID_CHARACTERS"],
    ["a bidi override", "‮Lan", "INVALID_CHARACTERS"],
  ])("refuses %s on the field, without calling anything", async (_name, value, error) => {
    const calls = patchServer();
    expect(await rename(value)).toEqual({
      value: value ?? "",
      fieldError: error,
      formError: null,
      retryAfterSeconds: null,
      saved: null,
    });
    expect(calls).toEqual([]);
    expect(request.refreshes).toBe(0);
  });

  it("sends a user without a session cookie to log in and back to /me", async () => {
    expect(await redirectTarget(rename("Lan Phương"))).toBe(loginTarget);
  });

  it("answers UNAVAILABLE when the session store cannot be reached", async () => {
    request.cookies.set("svp_sid", "d".repeat(43));
    expect(await rename("Lan Phương")).toMatchObject({ value: "Lan Phương", formError: "UNAVAILABLE", saved: null });
  });
});

describe.skipIf(!testRedisURL)("updateDisplayNameAction on the test Redis", () => {
  const redis = useTestRedis();

  async function logIn(accessExpiresInMs?: number) {
    const tokens = fakeTokens(userId, accessExpiresInMs);
    const { sid } = await request.services!.store.create(userId, tokens);
    request.cookies.set("svp_sid", sid);
    return { sid, tokens };
  }

  beforeEach(() => {
    request.services = testServices(redis.client(), redis.prefix());
  });

  it("sends PATCH /me with the session's token, refreshes the page and returns the stored name", async () => {
    const { tokens } = await logIn();
    const calls = patchServer();

    const state = await rename("  Lan Phương  ");

    expect(state).toEqual({
      value: "Lan Phương",
      fieldError: null,
      formError: null,
      retryAfterSeconds: null,
      saved: "Lan Phương",
    });
    expect(calls).toEqual([
      {
        body: { display_name: "Lan Phương" },
        authorization: `Bearer ${tokens.access_token}`,
        forwardedFor: "203.0.113.9",
      },
    ]);
    expect(request.refreshes).toBe(1);
    expect(JSON.stringify(state)).not.toContain("eyJ");
  });

  it.each([
    ["HTML", "<script>alert(1)</script><b>Lan</b>"],
    ["emoji with a ZWJ", "Lan 👩‍👩‍👧"],
    // 7 × "Phương " is 49 characters, so one more letter makes 50.
    ["50 Vietnamese characters", "Phương ".repeat(7) + "L"],
    ["text in Vietnamese", "Nguyễn Thị Lan Phương"],
  ])("passes %s on unchanged", async (_name, value) => {
    await logIn();
    const calls = patchServer();
    expect((await rename(value)).saved).toBe(value.trim());
    expect(calls[0]?.body).toEqual({ display_name: value.trim() });
  });

  it("sends Vietnamese typed in decomposed form as composed text, counted as it reads", async () => {
    await logIn();
    const calls = patchServer();
    // 50 characters once composed, 100 code points as typed.
    const decomposed = "ơ".repeat(50).normalize("NFD");
    expect(Array.from(decomposed)).toHaveLength(100);
    expect((await rename(decomposed)).saved).toBe("ơ".repeat(50));
    expect(calls[0]?.body).toEqual({ display_name: "ơ".repeat(50) });
  });

  it("refreshes an expired access token first", async () => {
    await logIn(-1000);
    const refreshed = fakeTokens(userId);
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => HttpResponse.json(accessTokenBody(refreshed))));
    const calls = patchServer();
    expect((await rename("Lan")).saved).toBe("Lan");
    expect(calls[0]?.authorization).toBe(`Bearer ${refreshed.access_token}`);
  });

  it("sends an unknown sid to log in", async () => {
    request.cookies.set("svp_sid", "b".repeat(43));
    expect(await redirectTarget(rename("Lan"))).toBe(loginTarget);
  });

  it("sends the user to log in when the session expired and its refresh is refused", async () => {
    await logIn(-1000);
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(401, "INVALID_REFRESH_TOKEN")));
    const calls = patchServer();
    expect(await redirectTarget(rename("Lan"))).toBe(loginTarget);
    expect(calls).toEqual([]);
  });

  it("ends the session and sends the user to log in when the gateway refuses the token", async () => {
    const { sid, tokens } = await logIn();
    const logouts = recordLogouts();
    patchServer(() => gatewayProblem(401, "UNAUTHENTICATED"));
    expect(await redirectTarget(rename("Lan"))).toBe(loginTarget);
    expect(await request.services!.store.get(sid)).toBeNull();
    expect(logouts).toEqual([tokens.refresh_token]);
    expect(request.refreshes).toBe(0);
  });

  it("shows user-service refusing the name on the field", async () => {
    await logIn();
    patchServer(() => gatewayProblem(400, "INVALID_DISPLAY_NAME"));
    expect(await rename("Lan")).toEqual({
      value: "Lan",
      fieldError: "INVALID_DISPLAY_NAME",
      formError: null,
      retryAfterSeconds: null,
      saved: null,
    });
    expect(request.refreshes).toBe(0);
  });

  it("hands the Retry-After of a 429 to the form", async () => {
    await logIn();
    patchServer(() => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "17" }));
    expect(await rename("Lan")).toMatchObject({ formError: "RATE_LIMITED", retryAfterSeconds: 17, saved: null });
  });

  it("hands the Retry-After of a rate-limited refresh to the form", async () => {
    await logIn(-1000);
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "9" })),
    );
    expect(await rename("Lan")).toMatchObject({ formError: "RATE_LIMITED", retryAfterSeconds: 9 });
  });

  it.each([
    ["404 USER_NOT_FOUND", () => gatewayProblem(404, "USER_NOT_FOUND")],
    ["400 INVALID_JSON", () => gatewayProblem(400, "INVALID_JSON")],
    ["503", () => gatewayProblem(503, "UNAVAILABLE")],
    ["a network error", () => HttpResponse.error()],
  ])("answers UNAVAILABLE on %s", async (_name, answer) => {
    await logIn();
    patchServer(answer);
    expect(await rename("Lan")).toMatchObject({
      value: "Lan",
      fieldError: null,
      formError: "UNAVAILABLE",
      saved: null,
    });
    expect(request.refreshes).toBe(0);
  });
});
