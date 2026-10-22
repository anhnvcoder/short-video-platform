import { describe, expect, it } from "vitest";
import { checkDisplayName } from "./display-name";

// The rules of docs/adr/0018-web-profiles-public-video-upload.md, section 2, with its edge cases.
describe("checkDisplayName", () => {
  it.each([
    ["Lan Phương", "Lan Phương"],
    ["  Lan Phương \n", "Lan Phương"],
    ["<script>alert(1)</script>", "<script>alert(1)</script>"],
    ["Lan 👩‍👩‍👧", "Lan 👩‍👩‍👧"],
    ["ệ".repeat(50), "ệ".repeat(50)],
    // An emoji is one character, though two UTF-16 units.
    ["😀".repeat(50), "😀".repeat(50)],
    // Decomposed Vietnamese is composed before it is counted.
    ["ệ".repeat(50).normalize("NFD"), "ệ".repeat(50)],
  ])("accepts %j as %j", (input, value) => {
    expect(checkDisplayName(input)).toEqual({ ok: true, value });
  });

  it.each([
    ["", "REQUIRED"],
    ["   ", "REQUIRED"],
    ["\n\t", "REQUIRED"],
    [undefined, "REQUIRED"],
    [42, "REQUIRED"],
    ["ệ".repeat(51), "TOO_LONG"],
    ["😀".repeat(51), "TOO_LONG"],
    ["Lan\nPhương", "INVALID_CHARACTERS"],
    ["Lan\rPhương", "INVALID_CHARACTERS"],
    ["Lan\tPhương", "INVALID_CHARACTERS"],
    ["Lan\u0000", "INVALID_CHARACTERS"],
    ["Lan\u007f", "INVALID_CHARACTERS"],
    ["Lan\u0085Phương", "INVALID_CHARACTERS"],
    ["Lan Phương", "INVALID_CHARACTERS"],
    ["Lan Phương", "INVALID_CHARACTERS"],
    ["‮Lan", "INVALID_CHARACTERS"],
    ["Lan‏", "INVALID_CHARACTERS"],
    ["Lan⁦x", "INVALID_CHARACTERS"],
    ["Lan\ud800", "INVALID_CHARACTERS"],
  ])("refuses %j with %s", (input, error) => {
    expect(checkDisplayName(input)).toEqual({ ok: false, error });
  });
});
