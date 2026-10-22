import { createServer, type AddressInfo } from "node:net";
import { NextRequest } from "next/server";
import { afterAll, beforeEach, describe, expect, it, vi } from "vitest";
import { initialAuthState } from "./auth-state";

// The BFF's real runtime with REDIS_URL on a port nothing listens on (opened by this test, then closed): every entry
// point answers at once with its error instead of waiting for Redis.

const request = vi.hoisted(() => ({ cookies: new Map<string, string>(), headers: new Headers() }));

vi.mock("next/headers", () => ({
  cookies: async () => ({
    get: (name: string) => {
      const value = request.cookies.get(name);
      return value === undefined ? undefined : { name, value };
    },
    set: (name: string, value: string) => request.cookies.set(name, value),
  }),
  headers: async () => request.headers,
}));

async function closedPort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

vi.stubEnv("GATEWAY_URL", "http://gateway.test");
vi.stubEnv("REDIS_URL", `redis://127.0.0.1:${await closedPort()}/15`);
vi.stubEnv("APP_ORIGIN", "http://localhost:3001");
vi.stubEnv("MEDIA_ORIGIN", "http://127.0.0.1:9000");
vi.stubEnv("UPLOAD_ORIGIN", "http://127.0.0.1:9000");

const api = await import("@/app/api/[...path]/route");
const logout = await import("@/app/logout/route");
const { loginAction, registerAction } = await import("./auth-actions");
const { getCurrentUser, requireSession } = await import("./current-user");
const { loadFirstFeedPage } = await import("./feed");

const sid = "a".repeat(43);

function form(fields: Record<string, string>): FormData {
  const data = new FormData();
  for (const [name, value] of Object.entries(fields)) {
    data.set(name, value);
  }
  return data;
}

async function thrownBy(run: Promise<unknown>): Promise<(Error & { digest?: string }) | undefined> {
  return run.then(
    () => undefined,
    (thrown: unknown) => thrown as Error & { digest?: string },
  );
}

beforeEach(() => {
  request.cookies = new Map([["svp_sid", sid]]);
  request.headers = new Headers();
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterAll(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("with the session Redis unreachable", () => {
  it("/api/* answers 503", async () => {
    const started = Date.now();
    const response = await api.GET(
      new NextRequest("http://localhost:3001/api/feed/explore", { headers: { cookie: `svp_sid=${sid}` } }),
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ code: "UNAVAILABLE" });
    expect(Date.now() - started).toBeLessThan(1000);
  });

  it("login and register answer UNAVAILABLE without setting a cookie", async () => {
    const fields = form({ email: "a@example.com", password: "12345678", handle: "alice" });
    expect((await loginAction(initialAuthState, fields)).formError).toBe("UNAVAILABLE");
    expect((await registerAction(initialAuthState, fields)).formError).toBe("UNAVAILABLE");
    expect([...request.cookies.keys()]).toEqual(["svp_sid"]);
    expect(request.cookies.get("svp_sid")).toBe(sid);
  });

  it("POST /logout still clears the cookie and goes to /login", async () => {
    const response = await logout.POST(
      new NextRequest("http://localhost:3001/logout", { method: "POST", headers: { cookie: `svp_sid=${sid}` } }),
    );
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("/login");
    expect(response.headers.get("set-cookie")).toBe("svp_sid=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0");
    expect(response.headers.get("clear-site-data")).toBe('"cache"');
  });

  it("pages that need a login send a visitor without a cookie to /login instead of failing", async () => {
    request.cookies.clear();
    request.headers = new Headers({ "x-svp-path": "/following" });
    const started = Date.now();
    for (const run of [requireSession(), loadFirstFeedPage("following")]) {
      expect((await thrownBy(run))?.digest).toMatch(/^NEXT_REDIRECT;replace;\/login\?next=%2Ffollowing;/);
    }
    expect(await getCurrentUser()).toBeNull();
    expect(Date.now() - started).toBeLessThan(1000);
  });

  it("pages that need a login fail as before for a visitor with a cookie", async () => {
    request.headers = new Headers({ "x-svp-path": "/following" });
    for (const run of [requireSession(), getCurrentUser(), loadFirstFeedPage("following")]) {
      const error = await thrownBy(run);
      expect(error).toBeInstanceOf(Error);
      expect(error?.digest).toBeUndefined();
    }
  });
});
