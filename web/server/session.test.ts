import { describe, expect, it, vi } from "vitest";
import type { Redis } from "./redis";
import {
  commandTimeoutMs,
  hashSid,
  isSid,
  newSid,
  serializeSessionCookie,
  sessionCookieName,
  sessionCookieOptions,
  SessionStore,
  type Session,
} from "./session";
import { fakeTokens } from "./testing/bff";
import { testRedisURL, useTestRedis } from "./testing/redis";

const userId = "01928c6e-7b3a-7cde-8f01-23456789abcd";

describe("sid", () => {
  it("is 32 random bytes in base64url without padding", () => {
    const sid = newSid();
    expect(sid).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(sid, "base64url")).toHaveLength(32);
    expect(newSid()).not.toBe(sid);
    expect(isSid(sid)).toBe(true);
  });

  it.each(["", "short", `${"a".repeat(43)}=`, "a".repeat(44), `${"a".repeat(42)}+`])("rejects %j", (value) => {
    expect(isSid(value)).toBe(false);
  });

  it("hashes to sha256 hex", () => {
    expect(hashSid("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
});

describe("session cookie", () => {
  it("on https is __Host-Http-svp_sid with Secure", () => {
    expect(sessionCookieName(true)).toBe("__Host-Http-svp_sid");
    expect(sessionCookieOptions(true)).toEqual({
      httpOnly: true,
      secure: true,
      path: "/",
      sameSite: "lax",
      maxAge: 2_592_000,
    });
    expect(serializeSessionCookie(true, "x", 2_592_000)).toBe(
      "__Host-Http-svp_sid=x; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=2592000",
    );
  });

  it("on http://localhost is svp_sid without prefix and without Secure", () => {
    expect(sessionCookieName(false)).toBe("svp_sid");
    expect(sessionCookieOptions(false).secure).toBe(false);
    expect(serializeSessionCookie(false, "", 0)).toBe("svp_sid=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0");
  });
});

describe("SessionStore on a Redis that keeps the connection but stops answering", () => {
  it("fails every command after commandTimeoutMs instead of holding the request open", async () => {
    const silent = () => new Promise<never>(() => {});
    const redis = { get: silent, set: silent, del: silent, eval: silent, exists: silent } as unknown as Redis;
    const store = new SessionStore(redis, "svp:test:silent:");
    const sid = newSid();
    const tokens = fakeTokens(userId);
    const session: Session = {
      ver: 1,
      user_id: userId,
      access_token: tokens.access_token,
      access_expires_at: tokens.expires_at,
      refresh_token: tokens.refresh_token,
      refresh_expires_at: tokens.refresh_expires_at,
      created_at: new Date().toISOString(),
    };
    vi.useFakeTimers();
    try {
      const outcomes = Promise.allSettled([
        store.create(userId, tokens),
        store.get(sid),
        store.delete(sid),
        store.compareAndSet(sid, session, fakeTokens(userId)),
        store.compareAndDelete(sid, session),
        store.acquireLock(sid, 5000),
        store.releaseLock(sid, "holder"),
        store.lockHeld(sid),
      ]);
      await vi.advanceTimersByTimeAsync(commandTimeoutMs);
      for (const outcome of await outcomes) {
        expect(outcome).toMatchObject({ status: "rejected", reason: { message: /no answer within 1000 ms/ } });
      }
    } finally {
      vi.useRealTimers();
    }
  });
});

describe.skipIf(!testRedisURL)("SessionStore on the test Redis", () => {
  const redis = useTestRedis();
  const store = () => new SessionStore(redis.client(), redis.prefix());

  it("stores the session under the hash of the sid, never the sid, with the refresh token's expiry as TTL", async () => {
    const tokens = fakeTokens(userId);
    const { sid, session } = await store().create(userId, tokens);

    expect(session).toMatchObject({
      ver: 1,
      user_id: userId,
      access_token: tokens.access_token,
      access_expires_at: tokens.expires_at,
      refresh_token: tokens.refresh_token,
      refresh_expires_at: tokens.refresh_expires_at,
    });
    const keys = await redis.client().keys(`${redis.prefix()}*`);
    expect(keys).toEqual([`${redis.prefix()}sess:${hashSid(sid)}`]);
    expect(keys.join()).not.toContain(sid);
    const expireAt = await redis.client().pExpireTime(keys[0] ?? "");
    expect(expireAt).toBe(Date.parse(tokens.refresh_expires_at));
    expect(await store().get(sid)).toEqual(session);
  });

  it("gives a fresh sid for every session", async () => {
    const a = await store().create(userId, fakeTokens(userId));
    const b = await store().create(userId, fakeTokens(userId));
    expect(a.sid).not.toBe(b.sid);
  });

  it("reads null for an unknown sid, a malformed sid and a value that is not a session", async () => {
    expect(await store().get(newSid())).toBeNull();
    expect(await store().get("../../etc")).toBeNull();
    const sid = newSid();
    await redis
      .client()
      .set(`${redis.prefix()}sess:${hashSid(sid)}`, "{not json", { expiration: { type: "EX", value: 60 } });
    expect(await store().get(sid)).toBeNull();
  });

  it("deletes a session", async () => {
    const { sid } = await store().create(userId, fakeTokens(userId));
    await store().delete(sid);
    expect(await store().get(sid)).toBeNull();
  });

  it("compare-and-set writes only at the version read, and never brings a deleted session back", async () => {
    const { sid, session } = await store().create(userId, fakeTokens(userId));
    const newer = fakeTokens(userId);

    const written = await store().compareAndSet(sid, session, newer);
    expect(written).toMatchObject({ ver: 2, refresh_token: newer.refresh_token });
    expect(await store().get(sid)).toEqual(written);
    expect(await redis.client().pExpireTime(`${redis.prefix()}sess:${hashSid(sid)}`)).toBe(
      Date.parse(newer.refresh_expires_at),
    );

    // A second writer that read version 1 loses.
    expect(await store().compareAndSet(sid, session, fakeTokens(userId))).toBeNull();
    expect(await store().get(sid)).toEqual(written);

    await store().delete(sid);
    expect(await store().compareAndSet(sid, written!, fakeTokens(userId))).toBeNull();
    expect(await store().get(sid)).toBeNull();
  });

  it("compare-and-delete deletes only at the version read", async () => {
    const { sid, session } = await store().create(userId, fakeTokens(userId));
    const written = await store().compareAndSet(sid, session, fakeTokens(userId));
    expect(await store().compareAndDelete(sid, session)).toBe(false);
    expect(await store().get(sid)).not.toBeNull();
    expect(await store().compareAndDelete(sid, written!)).toBe(true);
    expect(await store().get(sid)).toBeNull();
  });

  it("the refresh lease has one holder, expires, and is freed only by its holder", async () => {
    // A lease far longer than the 5 s a test may run, so its TTL is checked against a bound no slow machine can cross
    // while the test still passes.
    const leaseMs = 60_000;
    const sid = newSid();
    const first = await store().acquireLock(sid, leaseMs);
    expect(first).not.toBeNull();
    expect(await store().acquireLock(sid, leaseMs)).toBeNull();
    expect(await redis.client().pTTL(`${redis.prefix()}lock:${hashSid(sid)}`)).toBeGreaterThan(leaseMs - 5000);

    await store().releaseLock(sid, "someone-else");
    expect(await store().lockHeld(sid)).toBe(true);
    await store().releaseLock(sid, first!);
    expect(await store().lockHeld(sid)).toBe(false);
  });
});
