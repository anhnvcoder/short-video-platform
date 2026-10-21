import "server-only";
import { createHash, randomBytes } from "node:crypto";
import { z } from "zod";
import { withTimeout, type Redis } from "./redis";

// Server-side sessions in Redis (docs/adr/0016-web-client.md, section 5). The browser holds only a random session id
// (sid) in an HttpOnly cookie; the tokens stay here and never reach a page, a response or a log.
//
// Keys: <prefix>sess:<sha256(sid) hex> holds the session JSON, <prefix>lock:<sha256(sid) hex> the refresh lease. Only
// the hash is stored, so whoever reads Redis (KEYS, a dump) cannot rebuild a cookie. The prefix is svp:web: in the app
// and a random svp:test:<hex>: in tests.

export const defaultKeyPrefix = "svp:web:";

// The cookie lives as long as a refresh token family can (30 days after login); the session's real lifetime is the TTL
// of its Redis key, pushed to refresh_expires_at at every refresh.
export const sessionCookieMaxAgeSeconds = 30 * 24 * 60 * 60;

const sessionSchema = z.object({
  // Grows by one at every write, for compare-and-set.
  ver: z.number().int().positive(),
  user_id: z.string(),
  access_token: z.string(),
  access_expires_at: z.string(),
  refresh_token: z.string(),
  refresh_expires_at: z.string(),
  created_at: z.string(),
});

export type Session = z.infer<typeof sessionSchema>;

export interface TokenSet {
  access_token: string;
  expires_at: string;
  refresh_token: string;
  refresh_expires_at: string;
}

// 32 random bytes, base64url without padding: always 43 characters.
export function newSid(): string {
  return randomBytes(32).toString("base64url");
}

const sidPattern = /^[A-Za-z0-9_-]{43}$/;

export function isSid(value: string): boolean {
  return sidPattern.test(value);
}

export function hashSid(sid: string): string {
  return createHash("sha256").update(sid).digest("hex");
}

// http://localhost (compose, `make web-dev`) gets a cookie without Secure and without a prefix: WebKit drops Secure
// cookies set from http://localhost (WebKit bug 232088), and __Host- requires Secure. https gets __Host-Http-: no
// Domain, so sibling hosts such as s3.svp.localhost cannot overwrite it, and HttpOnly is enforced by the name.
export function sessionCookieName(secure: boolean): string {
  return secure ? "__Host-Http-svp_sid" : "svp_sid";
}

export interface SessionCookieOptions {
  httpOnly: true;
  secure: boolean;
  path: "/";
  // Lax, not Strict: a link to a video opened from another site must arrive logged in. CSRF is stopped by the
  // Fetch Metadata check of proxy.ts, not by SameSite.
  sameSite: "lax";
  maxAge: number;
}

export function sessionCookieOptions(secure: boolean, maxAge = sessionCookieMaxAgeSeconds): SessionCookieOptions {
  return { httpOnly: true, secure, path: "/", sameSite: "lax", maxAge };
}

// The Set-Cookie value for handlers that build their response by hand; the same name and attributes as the cookie set
// at login, which a browser needs to replace or delete it.
export function serializeSessionCookie(secure: boolean, value: string, maxAge: number): string {
  return [
    `${sessionCookieName(secure)}=${value}`,
    "HttpOnly",
    ...(secure ? ["Secure"] : []),
    "Path=/",
    "SameSite=Lax",
    `Max-Age=${maxAge}`,
  ].join("; ");
}

// Writes the new session only if the key still exists and still holds the version read before; a session deleted by
// a logout during a refresh is not brought back, and a write that lost a race does not overwrite the winner.
const compareAndSetScript = `
local current = redis.call('GET', KEYS[1])
if not current then return 0 end
local ok, session = pcall(cjson.decode, current)
if not ok or type(session) ~= 'table' or session.ver ~= tonumber(ARGV[1]) then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'PXAT', ARGV[3])
return 1
`;

const compareAndDeleteScript = `
local current = redis.call('GET', KEYS[1])
if not current then return 0 end
local ok, session = pcall(cjson.decode, current)
if not ok or type(session) ~= 'table' or session.ver ~= tonumber(ARGV[1]) then return 0 end
return redis.call('DEL', KEYS[1])
`;

// Deletes the lease only while it still holds this holder's random value: a holder whose lease ran out must not free
// the lease another replica took since.
const releaseLockScript = `
if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0
`;

// How long a session command waits for its answer. The Redis client times out only commands it has not written yet
// (and, without an offline queue, fails them at once while disconnected); a command written to a Redis that keeps the
// connection open but stops answering would wait until TCP gives up, and hold its request open as long.
export const commandTimeoutMs = 1000;

function bounded<T>(command: Promise<T>): Promise<T> {
  return withTimeout(command, commandTimeoutMs, "no answer");
}

export class SessionStore {
  constructor(
    private readonly redis: Redis,
    private readonly prefix = defaultKeyPrefix,
    private readonly now: () => number = Date.now,
  ) {}

  private sessionKey(sid: string): string {
    return `${this.prefix}sess:${hashSid(sid)}`;
  }

  private lockKey(sid: string): string {
    return `${this.prefix}lock:${hashSid(sid)}`;
  }

  // Stores a new session under a fresh sid; the key expires with the refresh token.
  async create(userId: string, tokens: TokenSet): Promise<{ sid: string; session: Session }> {
    const sid = newSid();
    const session: Session = {
      ver: 1,
      user_id: userId,
      ...sessionTokens(tokens),
      created_at: new Date(this.now()).toISOString(),
    };
    await bounded(
      this.redis.set(this.sessionKey(sid), JSON.stringify(session), {
        condition: "NX",
        expiration: { type: "PXAT", value: Date.parse(session.refresh_expires_at) },
      }),
    );
    return { sid, session };
  }

  // The session of sid, or null for a malformed sid (no Redis call), an unknown one or a value that is not a session.
  async get(sid: string): Promise<Session | null> {
    if (!isSid(sid)) {
      return null;
    }
    const raw = await bounded(this.redis.get(this.sessionKey(sid)));
    if (raw === null) {
      return null;
    }
    try {
      const parsed = sessionSchema.safeParse(JSON.parse(raw));
      return parsed.success ? parsed.data : null;
    } catch {
      return null;
    }
  }

  async delete(sid: string): Promise<void> {
    if (isSid(sid)) {
      await bounded(this.redis.del(this.sessionKey(sid)));
    }
  }

  // Replaces the tokens of the session at version `expected`; returns the new session, or null when the session is
  // gone or was written by someone else since.
  async compareAndSet(sid: string, expected: Session, tokens: TokenSet): Promise<Session | null> {
    const next: Session = { ...expected, ...sessionTokens(tokens), ver: expected.ver + 1 };
    const written = await bounded(
      this.redis.eval(compareAndSetScript, {
        keys: [this.sessionKey(sid)],
        arguments: [String(expected.ver), JSON.stringify(next), String(Date.parse(next.refresh_expires_at))],
      }),
    );
    return written === 1 ? next : null;
  }

  // Deletes the session only while it is still at version `expected`.
  async compareAndDelete(sid: string, expected: Session): Promise<boolean> {
    const deleted = await bounded(
      this.redis.eval(compareAndDeleteScript, { keys: [this.sessionKey(sid)], arguments: [String(expected.ver)] }),
    );
    return deleted === 1;
  }

  // Takes the refresh lease of sid for leaseMs; returns the holder's random value, or null when another holds it.
  async acquireLock(sid: string, leaseMs: number): Promise<string | null> {
    const holder = randomBytes(16).toString("hex");
    const taken = await bounded(
      this.redis.set(this.lockKey(sid), holder, { condition: "NX", expiration: { type: "PX", value: leaseMs } }),
    );
    return taken === "OK" ? holder : null;
  }

  async releaseLock(sid: string, holder: string): Promise<void> {
    await bounded(this.redis.eval(releaseLockScript, { keys: [this.lockKey(sid)], arguments: [holder] }));
  }

  async lockHeld(sid: string): Promise<boolean> {
    return (await bounded(this.redis.exists(this.lockKey(sid)))) === 1;
  }
}

function sessionTokens(
  tokens: TokenSet,
): Pick<Session, "access_token" | "access_expires_at" | "refresh_token" | "refresh_expires_at"> {
  return {
    access_token: tokens.access_token,
    access_expires_at: tokens.expires_at,
    refresh_token: tokens.refresh_token,
    refresh_expires_at: tokens.refresh_expires_at,
  };
}
