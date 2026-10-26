import { describe, expect, it } from "vitest";
import { formatCompact, formatRelativeTime } from "./format";

// Intl puts a no-break space between the number and the unit.
const nbsp = " ";

describe("formatCompact", () => {
  it.each([
    [956, "956"],
    [1000, `1${nbsp}N`],
    [12_430, `12,4${nbsp}N`],
    [999_999, `999,9${nbsp}N`],
    [1_200_000, `1,2${nbsp}Tr`],
    [3_450_000, `3,4${nbsp}Tr`],
    [1_100_000_000, `1,1${nbsp}Tỷ`],
  ])("writes %d as %s in Vietnamese, matching the design table", (value, expected) => {
    expect(formatCompact(value, "vi")).toBe(expected);
  });

  it("cuts instead of rounding, so a count never shows the next unit early", () => {
    expect(formatCompact(1999, "vi")).toBe(`1,9${nbsp}N`);
    expect(formatCompact(999_999, "en")).toBe("999.9K");
  });

  it("drops a zero decimal", () => {
    expect(formatCompact(2000, "vi")).toBe(`2${nbsp}N`);
  });

  it("formats English with its own units", () => {
    expect(formatCompact(12_430, "en")).toBe("12.4K");
    expect(formatCompact(1_200_000, "en")).toBe("1.2M");
    expect(formatCompact(1_100_000_000, "en")).toBe("1.1B");
  });

  it("spells the unit out for screen readers", () => {
    expect(formatCompact(12_430, "vi", "long")).toBe("12,4 nghìn");
    expect(formatCompact(1_100_000_000, "vi", "long")).toBe("1,1 tỷ");
    expect(formatCompact(12_430, "en", "long")).toBe("12.4 thousand");
  });
});

describe("formatRelativeTime", () => {
  // A fixed clock: 2026-10-22 10:00 in Vietnam.
  const now = Date.parse("2026-10-22T03:00:00Z");
  const zone = "Asia/Ho_Chi_Minh";
  const ago = (ms: number) => new Date(now - ms).toISOString();
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;

  it.each([
    ["vi", 0, "vừa xong"],
    ["vi", 59_999, "vừa xong"],
    ["vi", minute, "1 phút trước"],
    ["vi", 59 * minute, "59 phút trước"],
    ["vi", hour, "1 giờ trước"],
    ["vi", 23 * hour + 59 * minute, "23 giờ trước"],
    ["vi", day, "1 ngày trước"],
    ["vi", 2 * day, "2 ngày trước"],
    ["vi", 7 * day - 1, "6 ngày trước"],
    ["vi", 7 * day, "15 thg 10"],
    ["en", 30_000, "just now"],
    ["en", 5 * minute, "5 minutes ago"],
    ["en", 3 * hour, "3 hours ago"],
    ["en", day, "1 day ago"],
    ["en", 6 * day, "6 days ago"],
    ["en", 30 * day, "Sep 22"],
  ])("%s, %d ms ago: %j", (locale, elapsed, expected) => {
    const justNow = locale === "vi" ? "vừa xong" : "just now";
    expect(formatRelativeTime(ago(elapsed), now, locale, zone, justNow)).toBe(expected);
  });

  it("writes the year of a date from another year", () => {
    expect(formatRelativeTime("2025-10-01T08:00:00Z", now, "vi", zone, "vừa xong")).toBe("1 thg 10, 2025");
    expect(formatRelativeTime("2025-10-01T08:00:00Z", now, "en", zone, "just now")).toBe("Oct 1, 2025");
  });

  it("takes the calendar day of the time zone, not of UTC", () => {
    // 2026-10-01 20:00 UTC is already 2 October in Vietnam.
    expect(formatRelativeTime("2026-10-01T20:00:00Z", now, "en", zone, "just now")).toBe("Oct 2");
  });

  it("reads a time slightly ahead of the clock as just now", () => {
    expect(formatRelativeTime(new Date(now + 5 * minute).toISOString(), now, "en", zone, "just now")).toBe("just now");
  });

  it("is null for a value that is not a date", () => {
    expect(formatRelativeTime("yesterday", now, "en", zone, "just now")).toBeNull();
  });
});
