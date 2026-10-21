import { describe, expect, it } from "vitest";
import { resolveLocale } from "./locale";

describe("resolveLocale", () => {
  it("takes a supported svp_locale cookie over Accept-Language", () => {
    expect(resolveLocale("en", "vi-VN,vi;q=0.9")).toBe("en");
    expect(resolveLocale("vi", "en-US")).toBe("vi");
  });

  it("ignores a cookie naming an unsupported locale", () => {
    expect(resolveLocale("fr", "en-US,en;q=0.9")).toBe("en");
    expect(resolveLocale("EN", null)).toBe("vi");
  });

  it("picks the supported language with the highest weight, by primary subtag", () => {
    expect(resolveLocale(undefined, "en-US,en;q=0.9,vi;q=0.8")).toBe("en");
    expect(resolveLocale(undefined, "fr-FR,fr;q=0.9,vi;q=0.5,en;q=0.4")).toBe("vi");
    expect(resolveLocale(undefined, "vi;q=0.3, EN-GB;q=0.7")).toBe("en");
  });

  it("keeps header order between equal weights", () => {
    expect(resolveLocale(undefined, "en, vi")).toBe("en");
    expect(resolveLocale(undefined, "vi;q=0.8, en;q=0.8")).toBe("vi");
  });

  it("skips q=0 and malformed weights", () => {
    expect(resolveLocale(undefined, "en;q=0, vi;q=0.1")).toBe("vi");
    expect(resolveLocale(undefined, "en;q=abc")).toBe("vi");
    expect(resolveLocale(undefined, "en;q=2")).toBe("vi");
  });

  it("falls back to Vietnamese", () => {
    expect(resolveLocale(undefined, null)).toBe("vi");
    expect(resolveLocale(undefined, "")).toBe("vi");
    expect(resolveLocale(undefined, "fr-FR, de")).toBe("vi");
    expect(resolveLocale(undefined, "*")).toBe("vi");
    expect(resolveLocale(undefined, ";;,,=")).toBe("vi");
  });
});
