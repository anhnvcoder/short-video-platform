import { http, HttpResponse } from "msw";
import { describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { checkCredentials, checkRegistration, failureState, safeNext, signIn, signOut } from "./auth";
import { createAuthGateway, subjectOf } from "./gateway";
import {
  accessTokenBody,
  fakeAccessToken,
  fakeTokens,
  gatewayOrigin,
  gatewayProblem,
  recordLogouts,
  testServices,
} from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
const appOrigin = "http://localhost:3001";

describe("safeNext", () => {
  it.each([
    ["//evil.example"],
    ["/\\evil.example"],
    ["https://evil.example"],
    ["/%2F%2Fevil.example"],
    ["/%2f/evil.example"],
    ["/%5Cevil.example"],
    ["javascript:alert(1)"],
    [""],
    ["feed"],
    ["/\tevil"],
    ["/%E0%A4%A"],
    // Resolve to //evil.example only once the URL parser has removed the dot segments.
    ["/a/..//evil.example"],
    ["/a/%2e%2e//evil.example"],
    ["/a/%2E%2E//evil.example"],
    ["/a/.%2e//evil.example"],
    ["/./a/../..//evil.example"],
    ["/a/..%2F%2Fevil.example/../..//x"],
    ["/a/../\\evil.example"],
    // The parser drops tabs and newlines, which would join / and / into //.
    ["/\t/evil.example"],
    ["/\n/evil.example"],
    ["/a/..\r\n//evil.example"],
  ])("sends %j to /", (next) => {
    expect(safeNext(next, appOrigin)).toBe("/");
  });

  it.each([
    ["/a/..//evil.example"],
    ["/a/%2e%2e//evil.example"],
    ["/%2F%2Fevil.example"],
    ["/\\evil.example"],
    ["/a/../\\evil.example"],
    ["/a/..%2F%2Fevil.example"],
    ["/x/..?//evil.example"],
    ["/#//evil.example"],
  ])("never hands out a target a browser resolves to another origin: %j", (next) => {
    const target = safeNext(next, appOrigin);
    expect(target.startsWith("/")).toBe(true);
    expect(target.startsWith("//")).toBe(false);
    expect(new URL(target, appOrigin).origin).toBe(appOrigin);
    expect(new URL(target, "https://svp.localhost:8443").origin).toBe("https://svp.localhost:8443");
  });

  it("sends a missing value or a file to /", () => {
    expect(safeNext(null, appOrigin)).toBe("/");
    expect(safeNext(undefined, appOrigin)).toBe("/");
    expect(safeNext(new File(["x"], "next"), appOrigin)).toBe("/");
  });

  it.each([
    ["/", "/"],
    ["/following", "/following"],
    ["/v/01928c6e?x=1#top", "/v/01928c6e?x=1#top"],
    ["/a/../b", "/b"],
    ["/a/%2e%2e/b", "/b"],
    ["/a/..%2F%2Fevil.example", "/a/..%2F%2Fevil.example"],
    ["/x/..?//evil.example", "/?//evil.example"],
  ])("keeps the app path %j as %j", (next, expected) => {
    expect(safeNext(next, appOrigin)).toBe(expected);
  });
});

describe("checkCredentials", () => {
  it("accepts a valid email (trimmed) and a password of 8 to 128 characters", () => {
    expect(checkCredentials({ email: " a@example.com ", password: "12345678" })).toEqual({
      ok: true,
      email: "a@example.com",
      password: "12345678",
    });
  });

  it("flags each bad field with its code and sends the email back, never the password", () => {
    expect(checkCredentials({ email: "nope", password: "short" })).toEqual({
      ok: false,
      state: {
        email: "nope",
        handle: "",
        fieldErrors: { email: "INVALID_EMAIL", password: "INVALID_PASSWORD" },
        formError: null,
        retryAfterSeconds: null,
      },
    });
    expect(checkCredentials({ email: "a@example.com", password: "x".repeat(129) })).toMatchObject({
      ok: false,
      state: { fieldErrors: { password: "INVALID_PASSWORD" } },
    });
    expect(checkCredentials({ email: null, password: null })).toMatchObject({
      ok: false,
      state: { email: "", fieldErrors: { email: "INVALID_EMAIL", password: "INVALID_PASSWORD" } },
    });
  });

  it("counts the password in code points, as the user-service does", () => {
    // 128 characters outside the BMP are 256 UTF-16 units.
    expect(checkCredentials({ email: "a@example.com", password: "😀".repeat(128) })).toMatchObject({ ok: true });
    expect(checkCredentials({ email: "a@example.com", password: "😀".repeat(129) })).toMatchObject({
      ok: false,
      state: { fieldErrors: { password: "INVALID_PASSWORD" } },
    });
  });
});

describe("checkRegistration", () => {
  const valid = { email: "a@example.com", password: "12345678" };

  // The handle rule: trimmed, lowered for A-Z only, then 3-30 characters of [a-z0-9_] starting with a letter, and not
  // the generated form u_ + 12 hex digits, which only the server hands out
  // (docs/adr/0018-web-profiles-public-video-upload.md, section 1).
  it.each([
    ["Alice", "alice"],
    ["  bob\t", "bob"],
    ["MinhAnh_2", "minhanh_2"],
    ["a".repeat(30), "a".repeat(30)],
    ["u_bob", "u_bob"],
    ["u_0123456789abc", "u_0123456789abc"],
    ["abc", "abc"],
  ])("accepts the handle %j as %j", (handle, expected) => {
    expect(checkRegistration({ ...valid, handle })).toEqual({ ok: true, ...valid, handle: expected });
  });

  it.each([
    ["missing", null],
    ["empty", ""],
    ["blank", "   "],
    ["starting with _", "_bob"],
    ["starting with a digit", "1bob"],
    ["of 2 characters", "ab"],
    ["of 31 characters", "a".repeat(31)],
    ["with an accent", "bób"],
    ["with the Kelvin sign, which Unicode lowering makes k", "\u212Aelvin"],
    ["with a dash", "minh-anh"],
    ["with a space inside", "minh anh"],
    ["of the generated form", "u_0123456789ab"],
    ["of the generated form in upper case", "U_0123456789AB"],
    ["a file", new File(["alice"], "handle")],
  ])("flags a handle %s with INVALID_HANDLE", (_name, handle) => {
    expect(checkRegistration({ ...valid, handle })).toMatchObject({
      ok: false,
      state: { email: "a@example.com", fieldErrors: { handle: "INVALID_HANDLE" } },
    });
  });

  it("flags every bad field together and never sends the password back", () => {
    const checked = checkRegistration({ email: "nope", password: "short", handle: " Bad-Handle " });
    expect(checked).toEqual({
      ok: false,
      state: {
        email: "nope",
        handle: "bad-handle",
        fieldErrors: { email: "INVALID_EMAIL", password: "INVALID_PASSWORD", handle: "INVALID_HANDLE" },
        formError: null,
        retryAfterSeconds: null,
      },
    });
    expect(JSON.stringify(checked)).not.toContain("short");
  });
});

describe("failureState", () => {
  it.each(["INVALID_HANDLE", "HANDLE_ALREADY_TAKEN"] as const)("puts %s on the handle field", (code) => {
    expect(failureState("a@example.com", { ok: false, code }, "alice")).toEqual({
      email: "a@example.com",
      handle: "alice",
      fieldErrors: { handle: code },
      formError: null,
      retryAfterSeconds: null,
    });
  });
});

describe("subjectOf", () => {
  it("reads the user id from the access token", () => {
    expect(subjectOf(fakeAccessToken(userId))).toBe(userId);
  });

  it.each(["", "a.b", "a.eyJzdWIiOiJhZG1pbiJ9.c"])("is null for %j", (token) => {
    expect(subjectOf(token)).toBeNull();
  });
});

describe("AuthGateway.login and register answers", () => {
  const gateway = createAuthGateway(gatewayOrigin);

  it.each([
    [400, "INVALID_EMAIL", {}, { code: "INVALID_EMAIL" }],
    [400, "INVALID_PASSWORD", {}, { code: "INVALID_PASSWORD" }],
    [400, "INVALID_JSON", {}, { code: "UNAVAILABLE" }],
    [401, "INVALID_CREDENTIALS", {}, { code: "INVALID_CREDENTIALS" }],
    [409, "EMAIL_ALREADY_REGISTERED", {}, { code: "EMAIL_ALREADY_REGISTERED" }],
    [409, "HANDLE_ALREADY_TAKEN", {}, { code: "HANDLE_ALREADY_TAKEN" }],
    [400, "INVALID_HANDLE", {}, { code: "INVALID_HANDLE" }],
    [400, "INVALID_DISPLAY_NAME", {}, { code: "UNAVAILABLE" }],
    [409, "CONFLICT", {}, { code: "UNAVAILABLE" }],
    [429, "RATE_LIMITED", { "Retry-After": "42" }, { code: "RATE_LIMITED", retryAfterSeconds: 42 }],
    [503, "UNAVAILABLE", {}, { code: "UNAVAILABLE" }],
  ])("maps %d %s", async (status, code, headers, expected) => {
    server.use(
      http.post(`${gatewayOrigin}/auth/login`, () => gatewayProblem(status, code, headers)),
      http.post(`${gatewayOrigin}/auth/register`, () => gatewayProblem(status, code, headers)),
    );
    expect(await gateway.login("a@example.com", "12345678", null)).toEqual({ ok: false, ...expected });
    const account = { email: "a@example.com", password: "12345678", handle: "alice" };
    expect(await gateway.register(account, null)).toEqual({ ok: false, ...expected });
  });

  it("is UNAVAILABLE when the gateway cannot be reached", async () => {
    server.use(http.post(`${gatewayOrigin}/auth/login`, () => HttpResponse.error()));
    expect(await gateway.login("a@example.com", "12345678", null)).toEqual({ ok: false, code: "UNAVAILABLE" });
  });

  it("sends the credentials and X-Forwarded-For unchanged", async () => {
    let seen: { body: unknown; forwarded: string | null } | undefined;
    const tokens = fakeTokens(userId);
    server.use(
      http.post(`${gatewayOrigin}/auth/login`, async ({ request }) => {
        seen = { body: await request.json(), forwarded: request.headers.get("x-forwarded-for") };
        return HttpResponse.json(accessTokenBody(tokens));
      }),
    );
    expect(await gateway.login("a@example.com", "12345678", "203.0.113.9")).toEqual({ ok: true, userId, tokens });
    expect(seen).toEqual({ body: { email: "a@example.com", password: "12345678" }, forwarded: "203.0.113.9" });
  });
});

describe.skipIf(!testRedisURL)("signIn and signOut on the test Redis", () => {
  const redis = useTestRedis();

  it("starts a session under a fresh sid, ending the old one and revoking its family (no fixation)", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const old = await services.store.create(userId, fakeTokens(userId));
    const logouts = recordLogouts();
    const tokens = fakeTokens(userId);
    server.use(http.post(`${gatewayOrigin}/auth/login`, () => HttpResponse.json(accessTokenBody(tokens))));

    const result = await signIn(services, "a@example.com", "12345678", null, old.sid);

    expect(result.ok).toBe(true);
    const sid = result.ok ? result.sid : "";
    expect(sid).not.toBe(old.sid);
    expect(await services.store.get(old.sid)).toBeNull();
    expect(logouts).toEqual([old.session.refresh_token]);
    expect(await services.store.get(sid)).toMatchObject({ user_id: userId, refresh_token: tokens.refresh_token });
  });

  it("a planted sid without a session is simply ignored", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const logouts = recordLogouts();
    server.use(http.post(`${gatewayOrigin}/auth/login`, () => HttpResponse.json(accessTokenBody(fakeTokens(userId)))));
    const result = await signIn(services, "a@example.com", "12345678", null, "c".repeat(43));
    expect(result.ok).toBe(true);
    expect(logouts).toEqual([]);
  });

  it("returns the failure as form state and creates nothing", async () => {
    const services = testServices(redis.client(), redis.prefix());
    server.use(http.post(`${gatewayOrigin}/auth/login`, () => gatewayProblem(401, "INVALID_CREDENTIALS")));
    expect(await signIn(services, "a@example.com", "12345678", null, undefined)).toEqual({
      ok: false,
      state: {
        email: "a@example.com",
        handle: "",
        fieldErrors: {},
        formError: "INVALID_CREDENTIALS",
        retryAfterSeconds: null,
      },
    });
    expect(await redis.client().keys(`${redis.prefix()}*`)).toEqual([]);
  });

  it("signOut revokes the family and deletes the session, even when the gateway fails", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid } = await services.store.create(userId, fakeTokens(userId));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    server.use(http.post(`${gatewayOrigin}/auth/logout`, () => gatewayProblem(503, "UNAVAILABLE")));
    await signOut(services, sid, null);
    expect(await services.store.get(sid)).toBeNull();
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });
});
