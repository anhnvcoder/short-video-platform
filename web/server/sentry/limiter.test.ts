import { describe, expect, it } from "vitest";
import { EventLimiter, WindowBudget } from "./limiter";

function clock() {
  let now = 1_000_000;
  return {
    now: () => now,
    advance: (ms: number) => {
      now += ms;
    },
  };
}

describe("WindowBudget", () => {
  it("lets `limit` through in a window, then again as the oldest leave it", () => {
    const time = clock();
    const budget = new WindowBudget(20, 60_000, time.now);
    for (let i = 0; i < 20; i++) {
      expect(budget.take()).toBe(true);
      time.advance(1_000);
    }
    expect(budget.take()).toBe(false);
    // The first was taken 20 s ago; 40 s more and it leaves the window.
    time.advance(39_999);
    expect(budget.take()).toBe(false);
    time.advance(1);
    expect(budget.take()).toBe(true);
    expect(budget.take()).toBe(false);
  });
});

describe("EventLimiter", () => {
  it("sends one event per fingerprint every 30 s", () => {
    const time = clock();
    const limiter = new EventLimiter(time.now);
    expect(limiter.allow("a", false)).toBe(true);
    expect(limiter.allow("a", false)).toBe(false);
    expect(limiter.allow("b", false)).toBe(true);
    time.advance(29_999);
    expect(limiter.allow("a", true)).toBe(false);
    time.advance(1);
    expect(limiter.allow("a", false)).toBe(true);
  });

  it("sends at most 60 server errors a minute", () => {
    const time = clock();
    const limiter = new EventLimiter(time.now);
    for (let i = 0; i < 60; i++) {
      expect(limiter.allow(`server ${i}`, false)).toBe(true);
    }
    expect(limiter.allow("server 60", false)).toBe(false);
    time.advance(60_000);
    expect(limiter.allow("server 61", false)).toBe(true);
  });

  it("does not count browser reports against the server's budget, nor the other way round", () => {
    const time = clock();
    const limiter = new EventLimiter(time.now);
    for (let i = 0; i < 100; i++) {
      expect(limiter.allow(`browser ${i}`, true)).toBe(true);
    }
    for (let i = 0; i < 60; i++) {
      expect(limiter.allow(`server ${i}`, false)).toBe(true);
    }
    expect(limiter.allow("server 60", false)).toBe(false);
    expect(limiter.allow("browser 100", true)).toBe(true);
  });
});
