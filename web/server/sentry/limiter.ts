import "server-only";

// Bounds on what the web server sends to the error tracker, as for the Go services (internal/sentryx): a burst of one
// failure, or of junk reports from browsers, must not flood GlitchTip. Counters are per process, in memory.

// At most `limit` events in any `windowMs`.
export class WindowBudget {
  private readonly taken: number[] = [];

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  take(): boolean {
    const now = this.now();
    while (this.taken.length > 0 && now - (this.taken[0] ?? now) >= this.windowMs) {
      this.taken.shift();
    }
    if (this.taken.length >= this.limit) {
      return false;
    }
    this.taken.push(now);
    return true;
  }
}

// One event per fingerprint every 30 s, and the server's own errors within 60 a minute. Browser reports are not
// counted here: /monitoring already let at most 20 a minute through, on a budget of their own, so junk reports cannot
// push the server's errors out of theirs.
export class EventLimiter {
  private readonly last = new Map<string, number>();
  private readonly server: WindowBudget;

  constructor(private readonly now: () => number = Date.now) {
    this.server = new WindowBudget(60, 60_000, now);
  }

  allow(fingerprint: string, fromBrowser: boolean): boolean {
    const now = this.now();
    for (const [key, at] of this.last) {
      if (now - at >= 30_000) {
        this.last.delete(key);
      }
    }
    if (this.last.has(fingerprint) || (!fromBrowser && !this.server.take())) {
      return false;
    }
    this.last.set(fingerprint, now);
    return true;
  }
}
