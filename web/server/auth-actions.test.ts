import { http, HttpResponse } from "msw";
import { getURLFromRedirectError } from "next/dist/client/components/redirect";
import { isRedirectError } from "next/dist/client/components/redirect-error";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { initialAuthState } from "./auth-state";
import type { BffServices } from "./runtime";
import { accessTokenBody, fakeTokens, gatewayOrigin, gatewayProblem, testServices } from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

// The actions run outside a Next request here: cookies() and headers() are stand-ins, the services come from the
// test, and redirect() is Next's own, which throws an error whose digest names the target.
const request = vi.hoisted(() => ({
  cookies: new Map<string, { value: string; options: unknown }>(),
  headers: new Headers(),
  services: undefined as BffServices | undefined,
}));

vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: (name: string) => {
      const cookie = request.cookies.get(name);
      return cookie && { name, value: cookie.value };
    },
    set: (name: string, value: string, options: unknown) => request.cookies.set(name, { value, options }),
  }),
  headers: async () => request.headers,
}));

vi.mock("./runtime", () => ({
  bffServices: async () => {
    if (!request.services) {
      throw new Error("no services");
    }
    return request.services;
  },
}));

const { loginAction, registerAction } = await import("./auth-actions");

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";

function form(fields: Record<string, string>): FormData {
  const data = new FormData();
  for (const [name, value] of Object.entries(fields)) {
    data.set(name, value);
  }
  return data;
}

// Runs an action that should redirect and returns the Location header a form posted without JavaScript gets: Next's
// action handler answers 303 with getURLFromRedirectError(error) as the Location, unchanged.
async function redirectTarget(run: Promise<unknown>): Promise<string> {
  const error = await run.then(
    () => undefined,
    (thrown: unknown) => thrown,
  );
  expect(isRedirectError(error)).toBe(true);
  return isRedirectError(error) ? getURLFromRedirectError(error) : "";
}

beforeEach(() => {
  request.cookies.clear();
  request.headers = new Headers({ "x-forwarded-for": "203.0.113.5" });
  request.services = undefined;
});

describe("auth actions without a session store", () => {
  it("return field errors without calling the gateway", async () => {
    const state = await loginAction(initialAuthState, form({ email: "bad", password: "12345678" }));
    expect(state).toEqual({
      email: "bad",
      fieldErrors: { email: "INVALID_EMAIL" },
      formError: null,
      retryAfterSeconds: null,
    });
    expect(
      (await registerAction(initialAuthState, form({ email: "a@example.com", password: "1" }))).fieldErrors,
    ).toEqual({
      password: "INVALID_PASSWORD",
    });
  });

  it("answer UNAVAILABLE when the session store cannot be reached", async () => {
    const state = await loginAction(initialAuthState, form({ email: "a@example.com", password: "12345678" }));
    expect(state.formError).toBe("UNAVAILABLE");
  });
});

describe.skipIf(!testRedisURL)("auth actions on the test Redis", () => {
  const redis = useTestRedis();

  beforeEach(() => {
    request.services = testServices(redis.client(), redis.prefix());
  });

  it("loginAction sets the session cookie and redirects to the checked next", async () => {
    let forwarded: string | null = null;
    server.use(
      http.post(`${gatewayOrigin}/auth/login`, ({ request: call }) => {
        forwarded = call.headers.get("x-forwarded-for");
        return HttpResponse.json(accessTokenBody(fakeTokens(userId)));
      }),
    );

    const target = await redirectTarget(
      loginAction(initialAuthState, form({ email: "a@example.com", password: "12345678", next: "/following?tab=1" })),
    );

    expect(target).toBe("/following?tab=1");
    expect(forwarded).toBe("203.0.113.5");
    const cookie = request.cookies.get("svp_sid");
    expect(cookie?.options).toEqual({ httpOnly: true, secure: false, path: "/", sameSite: "lax", maxAge: 2_592_000 });
    expect(await request.services!.store.get(cookie!.value)).toMatchObject({ user_id: userId });
  });

  it.each([
    "//evil.example",
    "https://evil.example",
    "/%2F%2Fevil.example",
    "",
    "/a/..//evil.example",
    "/a/%2e%2e//evil.example",
    "/\\evil.example",
    "/a/../\\evil.example",
    "/\t/evil.example",
    "/\n/evil.example",
  ])("loginAction sends next=%j to /", async (next) => {
    server.use(http.post(`${gatewayOrigin}/auth/login`, () => HttpResponse.json(accessTokenBody(fakeTokens(userId)))));
    const location = await redirectTarget(
      loginAction(initialAuthState, form({ email: "a@example.com", password: "12345678", next })),
    );
    expect(location).toBe("/");
    // Where a browser goes with that Location.
    expect(new URL(location, "http://localhost:3001").origin).toBe("http://localhost:3001");
  });

  it("loginAction on https sets the __Host-Http- cookie with Secure", async () => {
    request.services = testServices(redis.client(), redis.prefix(), {
      env: { appOrigin: "https://svp.localhost:8443", secure: true },
    });
    server.use(http.post(`${gatewayOrigin}/auth/login`, () => HttpResponse.json(accessTokenBody(fakeTokens(userId)))));
    await redirectTarget(loginAction(initialAuthState, form({ email: "a@example.com", password: "12345678" })));
    expect(request.cookies.get("__Host-Http-svp_sid")?.options).toMatchObject({ secure: true, httpOnly: true });
    expect(request.cookies.has("svp_sid")).toBe(false);
  });

  it("loginAction returns RATE_LIMITED with the seconds of Retry-After", async () => {
    server.use(
      http.post(`${gatewayOrigin}/auth/login`, () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "30" })),
    );
    const state = await loginAction(initialAuthState, form({ email: "a@example.com", password: "12345678" }));
    expect(state).toEqual({
      email: "a@example.com",
      fieldErrors: {},
      formError: "RATE_LIMITED",
      retryAfterSeconds: 30,
    });
    expect(request.cookies.size).toBe(0);
  });

  it("registerAction registers, then logs in with the same credentials", async () => {
    const calls: string[] = [];
    server.use(
      http.post(`${gatewayOrigin}/auth/register`, async ({ request: call }) => {
        calls.push(`register ${JSON.stringify(await call.json())}`);
        return HttpResponse.json({ user_id: userId }, { status: 201 });
      }),
      http.post(`${gatewayOrigin}/auth/login`, async ({ request: call }) => {
        calls.push(`login ${JSON.stringify(await call.json())}`);
        return HttpResponse.json(accessTokenBody(fakeTokens(userId)));
      }),
    );
    const target = await redirectTarget(
      registerAction(initialAuthState, form({ email: "a@example.com", password: "12345678", next: "/" })),
    );
    expect(target).toBe("/");
    const body = JSON.stringify({ email: "a@example.com", password: "12345678" });
    expect(calls).toEqual([`register ${body}`, `login ${body}`]);
    expect(request.cookies.has("svp_sid")).toBe(true);
  });

  it("registerAction returns EMAIL_ALREADY_REGISTERED and does not log in", async () => {
    server.use(http.post(`${gatewayOrigin}/auth/register`, () => gatewayProblem(409, "EMAIL_ALREADY_REGISTERED")));
    const state = await registerAction(initialAuthState, form({ email: "a@example.com", password: "12345678" }));
    expect(state.formError).toBe("EMAIL_ALREADY_REGISTERED");
    expect(request.cookies.size).toBe(0);
  });
});
