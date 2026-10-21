import { delay, http, HttpResponse } from "msw";
import { afterEach, describe, expect, it, vi } from "vitest";
import { server } from "@/lib/test/msw-server";
import { SessionStore } from "./session";
import { SessionAccess } from "./session-access";
import { accessTokenBody, fakeTokens, gatewayOrigin, gatewayProblem, recordLogouts, testServices } from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";
// Valid for 10 more seconds: inside the 30 s before expiry, so due for a refresh but still usable.
const dueSoonMs = 10_000;

// Answers /auth/refresh with fresh tokens after `wait` ms and counts the calls.
function refreshes(wait = 50): { calls: string[] } {
  const calls: string[] = [];
  server.use(
    http.post(`${gatewayOrigin}/auth/refresh`, async ({ request }) => {
      calls.push(((await request.json()) as { refresh_token: string }).refresh_token);
      await delay(wait);
      return HttpResponse.json(accessTokenBody(fakeTokens(userId)));
    }),
  );
  return { calls };
}

// A gateway whose refresh tokens work once, as user-service's do: a token presented again is a replay, answered 401.
// A call with an unused token never gets an answer and stays open until the caller cuts it off; at that moment
// `leaseHeld` tells whether the caller still held its lease. maxOpen is the most calls that were open at once.
function hangingSingleUseRefresh(tokens: string[], leaseHeld: () => Promise<boolean>) {
  const unused = new Set(tokens);
  let open = 0;
  let opened: () => void = () => {};
  let cutOff: (held: Promise<boolean>) => void = () => {};
  const state = {
    calls: 0,
    maxOpen: 0,
    firstCallOpen: new Promise<void>((resolve) => (opened = resolve)),
    leaseHeldAtCutOff: new Promise<boolean>((resolve) => (cutOff = (held) => void held.then(resolve))),
  };
  server.use(
    http.post(`${gatewayOrigin}/auth/refresh`, async ({ request }) => {
      const { refresh_token: token } = (await request.json()) as { refresh_token: string };
      state.calls++;
      open++;
      state.maxOpen = Math.max(state.maxOpen, open);
      try {
        if (!unused.delete(token)) {
          return gatewayProblem(401, "INVALID_REFRESH_TOKEN");
        }
        opened();
        await new Promise<void>((resolve) =>
          request.signal.addEventListener(
            "abort",
            () => {
              cutOff(leaseHeld());
              resolve();
            },
            { once: true },
          ),
        );
        return HttpResponse.error();
      } finally {
        open--;
      }
    }),
  );
  return state;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe.skipIf(!testRedisURL)("SessionAccess on the test Redis", () => {
  const redis = useTestRedis();

  it("hands out the stored token without calling the gateway while it is not due", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid, session } = await services.store.create(userId, fakeTokens(userId));
    const { calls } = refreshes();
    expect(await services.access.access(sid, null)).toEqual({ kind: "ok", session });
    expect(calls).toHaveLength(0);
  });

  it("is logged out for a sid without a session", async () => {
    const services = testServices(redis.client(), redis.prefix());
    expect(await services.access.access("a".repeat(43), null)).toEqual({ kind: "none" });
  });

  it("10 requests of one process at once on a token due for refresh make exactly one refresh call", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    const { calls } = refreshes();

    const results = await Promise.all(Array.from({ length: 10 }, () => services.access.access(sid, "203.0.113.7")));

    expect(calls).toEqual([session.refresh_token]);
    const stored = await services.store.get(sid);
    expect(stored?.ver).toBe(2);
    for (const result of results) {
      expect(result).toEqual({ kind: "ok", session: stored });
    }
  });

  it("two replicas (no shared in-process map) with 10 requests between them make exactly one refresh call", async () => {
    const a = testServices(redis.client(), redis.prefix(), { pollMs: 10 });
    const b = new SessionAccess(new SessionStore(redis.client(), redis.prefix()), a.gateway, { pollMs: 10 });
    const { sid } = await a.store.create(userId, fakeTokens(userId, dueSoonMs));
    const { calls } = refreshes(100);

    const results = await Promise.all(
      Array.from({ length: 10 }, (_, i) => (i % 2 === 0 ? a.access : b).access(sid, null)),
    );

    expect(calls).toHaveLength(1);
    const stored = await a.store.get(sid);
    expect(stored?.ver).toBe(2);
    expect(results.every((result) => result.kind === "ok" && result.session.ver === 2)).toBe(true);
  });

  it("sends the X-Forwarded-For it was given to /auth/refresh, unchanged", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    let forwarded: string | null = null;
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, ({ request }) => {
        forwarded = request.headers.get("x-forwarded-for");
        return HttpResponse.json(accessTokenBody(fakeTokens(userId)));
      }),
    );
    await services.access.access(sid, "198.51.100.1, 10.42.0.9");
    expect(forwarded).toBe("198.51.100.1, 10.42.0.9");
  });

  it("ends the session when the gateway rejects the refresh token (401)", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(401, "INVALID_REFRESH_TOKEN")));

    expect(await services.access.access(sid, null)).toEqual({ kind: "none" });
    expect(await services.store.get(sid)).toBeNull();
  });

  it("keeps the session on a refresh timeout, uses the old token, and ends it when the retry is rejected", async () => {
    const services = testServices(redis.client(), redis.prefix(), { refreshTimeoutMs: 50 });
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, async () => {
        await delay(500);
        return HttpResponse.json(accessTokenBody(fakeTokens(userId)));
      }),
    );

    expect(await services.access.access(sid, null)).toEqual({ kind: "ok", session });
    expect(await services.store.get(sid)).toEqual(session);
    expect(warn).toHaveBeenCalled();
    for (const call of warn.mock.calls) {
      expect(JSON.stringify(call)).not.toContain(session.refresh_token);
      expect(JSON.stringify(call)).not.toContain(session.access_token);
    }

    // The first call may have rotated the token after all: the retry with the same token is a replay, which the
    // gateway answers with 401 after revoking the family.
    server.use(http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(401, "INVALID_REFRESH_TOKEN")));
    expect(await services.access.access(sid, null)).toEqual({ kind: "none" });
    expect(await services.store.get(sid)).toBeNull();
  });

  it("is logged out for the request, keeping the session, when the token has expired and the refresh times out", async () => {
    const services = testServices(redis.client(), redis.prefix(), { refreshTimeoutMs: 50 });
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, -1000));
    vi.spyOn(console, "warn").mockImplementation(() => {});
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, async () => {
        await delay(500);
        return HttpResponse.json(accessTokenBody(fakeTokens(userId)));
      }),
    );

    expect(await services.access.access(sid, null)).toEqual({ kind: "expired" });
    expect(await services.store.get(sid)).toEqual(session);
  });

  it("keeps the session on a 5xx without retrying the refresh", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, -1000));
    vi.spyOn(console, "warn").mockImplementation(() => {});
    let calls = 0;
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => {
        calls++;
        return gatewayProblem(503, "UNAVAILABLE");
      }),
    );
    expect(await services.access.access(sid, null)).toEqual({ kind: "expired" });
    expect(calls).toBe(1);
    expect(await services.store.get(sid)).toEqual(session);
  });

  it("passes a rate limited refresh on as 429 with its Retry-After once the token has expired", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid } = await services.store.create(userId, fakeTokens(userId, -1000));
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, () => gatewayProblem(429, "RATE_LIMITED", { "Retry-After": "7" })),
    );
    expect(await services.access.access(sid, null)).toEqual({ kind: "unavailable", status: 429, retryAfterSeconds: 7 });
  });

  // Lease 5 s, margin 4.3 s: the call is cut off 700 ms at most after the lease was asked for, and the lease is still
  // held at the cut-off even if a busy machine stalls this worker for seconds. A call left without that budget would
  // hang past the lease until the 30 s refresh timeout: B would then take the lease at 5 s and present the same token
  // while A's call is open (maxOpen 2), so the test's own timeout leaves room for that to show.
  it(
    "cuts its refresh call off before the lease runs out, so two replicas never present one token at once",
    { timeout: 15_000 },
    async () => {
      const options = { leaseMs: 5000, leaseMarginMs: 4300, waitMs: 10_000, pollMs: 10, refreshTimeoutMs: 30_000 };
      const a = testServices(redis.client(), redis.prefix(), options);
      const b = new SessionAccess(new SessionStore(redis.client(), redis.prefix()), a.gateway, options);
      const { sid, session } = await a.store.create(userId, fakeTokens(userId, dueSoonMs));
      vi.spyOn(console, "warn").mockImplementation(() => {});
      const gateway = hangingSingleUseRefresh([session.refresh_token], () => a.store.lockHeld(sid));

      const first = a.access.access(sid, null);
      await gateway.firstCallOpen;
      // A request on replica B meanwhile waits for the lease to be free, without calling the gateway.
      expect(await b.access(sid, null)).toEqual({ kind: "ok", session });
      expect(gateway.calls).toBe(1);
      // The next request on B takes the free lease and presents the token held. A's call must be over by then: the two
      // never overlap. The gateway had used that token up, so it is a replay and the session ends: the fail-closed choice
      // for an unknown outcome.
      expect(await b.access(sid, null)).toEqual({ kind: "none" });
      expect(gateway.calls).toBe(2);
      expect(gateway.maxOpen).toBe(1);
      expect(await a.store.get(sid)).toBeNull();
      // A cut its call off while it still held the lease, and kept the session with its still valid token.
      expect(await gateway.leaseHeldAtCutOff).toBe(true);
      expect(await first).toEqual({ kind: "ok", session });
    },
  );

  it("a logout during the refresh is not undone: the session stays deleted and the new family is revoked", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    const logouts = recordLogouts();
    const newTokens = fakeTokens(userId);
    let callStarted: () => void = () => {};
    const started = new Promise<void>((resolve) => (callStarted = resolve));
    let release: () => void = () => {};
    const answered = new Promise<void>((resolve) => (release = resolve));
    server.use(
      http.post(`${gatewayOrigin}/auth/refresh`, async () => {
        callStarted();
        await answered;
        return HttpResponse.json(accessTokenBody(newTokens));
      }),
    );

    const refreshing = services.access.access(sid, null);
    // The session is read again under the lease before the call, so the logout lands while the call is open.
    await started;
    await services.store.delete(sid);
    release();

    expect(await refreshing).toEqual({ kind: "none" });
    expect(await services.store.get(sid)).toBeNull();
    expect(logouts).toEqual([newTokens.refresh_token]);
  });

  it("skips the call when Redis left no time for it under the lease, keeping the session", async () => {
    // A margin as long as the lease leaves no budget at all.
    const services = testServices(redis.client(), redis.prefix(), { leaseMs: 1000, leaseMarginMs: 1000 });
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const { calls } = refreshes();
    expect(await services.access.access(sid, null)).toEqual({ kind: "ok", session });
    expect(calls).toHaveLength(0);
    expect(await services.store.lockHeld(sid)).toBe(false);
  });

  it("waits a bounded time for a lease held elsewhere, then answers 503 when the token has expired", async () => {
    const services = testServices(redis.client(), redis.prefix(), { waitMs: 150, pollMs: 20 });
    const { sid } = await services.store.create(userId, fakeTokens(userId, -1000));
    await services.store.acquireLock(sid, 5000);
    const { calls } = refreshes();

    const started = Date.now();
    expect(await services.access.access(sid, null)).toEqual({ kind: "unavailable", status: 503 });
    expect(Date.now() - started).toBeLessThan(1000);
    expect(calls).toHaveLength(0);
  });

  it("uses the old token after waiting when it is still valid", async () => {
    const services = testServices(redis.client(), redis.prefix(), { waitMs: 100, pollMs: 20 });
    const { sid, session } = await services.store.create(userId, fakeTokens(userId, dueSoonMs));
    await services.store.acquireLock(sid, 5000);
    expect(await services.access.access(sid, null)).toEqual({ kind: "ok", session });
  });

  it("end() deletes the session and revokes its family", async () => {
    const services = testServices(redis.client(), redis.prefix());
    const { sid, session } = await services.store.create(userId, fakeTokens(userId));
    const logouts = recordLogouts();
    await services.access.end(sid, session, null);
    expect(await services.store.get(sid)).toBeNull();
    expect(logouts).toEqual([session.refresh_token]);
  });
});
