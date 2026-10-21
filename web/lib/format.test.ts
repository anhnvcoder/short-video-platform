import { describe, expect, it } from "vitest";
import { formatCompact } from "./format";

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
