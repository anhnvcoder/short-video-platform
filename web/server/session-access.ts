import "server-only";
import type { AuthGateway } from "./gateway";
import { hashSid, type Session, type SessionStore } from "./session";

// Hands out a usable access token for a session, refreshing it shortly before it expires.
//
// A refresh token works once: presenting it a second time revokes the whole family and logs the user out. So at most
// one refresh per session may be in flight anywhere: requests of one process share one promise, and processes
// (replicas) share a Redis lease; whoever does not hold the lease waits for the new session instead of refreshing.
// The holder's call to the gateway, answer included, is cut off a margin before the lease runs out: a call still
// waiting past it would overlap with the call of the next holder, which presents the same token.
//
// When the outcome of a refresh is unknown (timeout, 5xx, lost answer) the session is kept and nothing is retried in
// this request: the gateway may already have rotated the token, and a retry would be a replay. The next request tries
// again with the token held; if it was in fact rotated, the gateway sees the replay, revokes the family, answers 401,
// and the session ends. That costs a login in the rare case the network failed right then, and keeps replay detection
// without any overlap window. Until then the old access token is used while it is still valid; once it has expired the
// request counts as logged out, without deleting the session.

export type AccessResult =
  | { kind: "ok"; session: Session }
  // No session, or it has ended (refresh token rejected, logout during the refresh).
  | { kind: "none" }
  // The access token has expired and the refresh outcome is unknown: logged out for this request, session kept.
  | { kind: "expired" }
  // The gateway rate limited the refresh (429) or another replica held the lease too long (503).
  | { kind: "unavailable"; status: 429 | 503; retryAfterSeconds?: number };

export interface SessionAccessOptions {
  // Lease of a refresh across replicas, and how much of it is kept free at the end: the refresh call must be over
  // by leaseMs - leaseMarginMs after the lease was asked for, else it is cut off and its outcome is unknown.
  leaseMs?: number;
  leaseMarginMs?: number;
  // How long a request waits for the replica that holds the lease, and how often it looks.
  waitMs?: number;
  pollMs?: number;
  now?: () => number;
}

// Refresh this long before the access token expires: the clock skew the gateway allows.
const refreshEarlyMs = 30_000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export class SessionAccess {
  private readonly inflight = new Map<string, Promise<AccessResult>>();
  private readonly leaseMs: number;
  private readonly leaseMarginMs: number;
  private readonly waitMs: number;
  private readonly pollMs: number;
  private readonly now: () => number;

  constructor(
    private readonly store: SessionStore,
    private readonly gateway: AuthGateway,
    options: SessionAccessOptions = {},
  ) {
    this.leaseMs = options.leaseMs ?? 5000;
    this.leaseMarginMs = options.leaseMarginMs ?? 1000;
    this.waitMs = options.waitMs ?? 5000;
    this.pollMs = options.pollMs ?? 100;
    this.now = options.now ?? Date.now;
  }

  async access(sid: string, forwardedFor: string | null): Promise<AccessResult> {
    const session = await this.store.get(sid);
    if (!session) {
      return { kind: "none" };
    }
    if (!this.needsRefresh(session)) {
      return { kind: "ok", session };
    }
    const key = hashSid(sid);
    let pending = this.inflight.get(key);
    if (!pending) {
      pending = this.refresh(sid, session, forwardedFor).finally(() => this.inflight.delete(key));
      this.inflight.set(key, pending);
    }
    return pending;
  }

  // Ends a session the gateway no longer accepts: deletes it unless it changed meanwhile, then revokes its refresh
  // token family on a best-effort basis.
  async end(sid: string, session: Session, forwardedFor: string | null): Promise<void> {
    if (await this.store.compareAndDelete(sid, session)) {
      await this.revoke(session.refresh_token, forwardedFor);
    }
  }

  private needsRefresh(session: Session): boolean {
    return Date.parse(session.access_expires_at) - refreshEarlyMs < this.now();
  }

  private usable(session: Session): AccessResult {
    return Date.parse(session.access_expires_at) > this.now() ? { kind: "ok", session } : { kind: "expired" };
  }

  private async refresh(sid: string, seen: Session, forwardedFor: string | null): Promise<AccessResult> {
    // Redis starts the lease when it runs the SET, which is after this instant, so a deadline counted from here ends
    // before the lease does. A monotonic clock: a wall clock step must not stretch the deadline.
    const asked = performance.now();
    const holder = await this.store.acquireLock(sid, this.leaseMs);
    if (holder === null) {
      return this.waitForHolder(sid, seen);
    }
    try {
      // Another replica may have refreshed between our read and the lease.
      const current = await this.store.get(sid);
      if (!current) {
        return { kind: "none" };
      }
      if (!this.needsRefresh(current)) {
        return { kind: "ok", session: current };
      }
      const budgetMs = Math.floor(asked + this.leaseMs - this.leaseMarginMs - performance.now());
      if (budgetMs <= 0) {
        // Redis took the whole budget: nothing was sent, so the next request can safely try again.
        console.warn("session refresh skipped: the refresh lease left no time for the call");
        return this.usable(current);
      }
      const result = await this.gateway.refresh(current.refresh_token, forwardedFor, AbortSignal.timeout(budgetMs));
      switch (result.kind) {
        case "rotated": {
          const next = await this.store.compareAndSet(sid, current, result.tokens);
          if (next) {
            return { kind: "ok", session: next };
          }
          // The session was logged out (or written by someone else) during the call: do not bring it back, and revoke
          // the family the new token belongs to.
          await this.revoke(result.tokens.refresh_token, forwardedFor);
          return { kind: "none" };
        }
        case "invalid":
          await this.store.compareAndDelete(sid, current);
          return { kind: "none" };
        case "rate-limited":
          return Date.parse(current.access_expires_at) > this.now()
            ? { kind: "ok", session: current }
            : { kind: "unavailable", status: 429, retryAfterSeconds: result.retryAfterSeconds };
        case "unknown":
          console.warn("session refresh outcome unknown; keeping the session for the next request to retry");
          return this.usable(current);
      }
    } finally {
      await this.store.releaseLock(sid, holder).catch(() => {
        // The lease expires by itself.
      });
    }
  }

  // Another replica (or a request of this one that lost the in-process race) holds the lease: wait for the session it
  // writes, without calling the gateway.
  private async waitForHolder(sid: string, seen: Session): Promise<AccessResult> {
    const deadline = this.now() + this.waitMs;
    for (;;) {
      await sleep(this.pollMs);
      let current = await this.store.get(sid);
      if (!current) {
        return { kind: "none" };
      }
      if (current.ver !== seen.ver) {
        return this.usable(current);
      }
      if (!(await this.store.lockHeld(sid))) {
        // The holder may have written just before it let go; read once more before concluding it gave up.
        current = await this.store.get(sid);
        if (!current) {
          return { kind: "none" };
        }
        return this.usable(current);
      }
      if (this.now() >= deadline) {
        return Date.parse(current.access_expires_at) > this.now()
          ? { kind: "ok", session: current }
          : { kind: "unavailable", status: 503 };
      }
    }
  }

  private async revoke(refreshToken: string, forwardedFor: string | null): Promise<void> {
    try {
      await this.gateway.logout(refreshToken, forwardedFor);
    } catch {
      console.warn("revoking a refresh token family failed; it expires by itself");
    }
  }
}
