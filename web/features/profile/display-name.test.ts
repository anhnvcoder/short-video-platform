import { describe, expect, it } from "vitest";
import { checkDisplayName } from "./display-name";

// The rules of docs/adr/0018-web-profiles-public-video-upload.md, section 2, with the cases of user-service's own test
// (TestDisplayNameRules in services/user-service/internal/server/profile_test.go), so both judge a name alike.
describe("checkDisplayName", () => {
  it.each([
    ["Lan Phương", "Lan Phương"],
    ["  Lan Phương \n", "Lan Phương"],
    ["  Nguyễn Văn A \t", "Nguyễn Văn A"],
    ["a b", "a b"],
    ["<script>alert(1)</script>", "<script>alert(1)</script>"],
    ["日本語の名前", "日本語の名前"],
    // Emoji ZWJ sequences and the emoji variation selector are allowed.
    ["Lan 👩‍👩‍👧", "Lan 👩‍👩‍👧"],
    ["👨‍👩‍👧", "👨‍👩‍👧"],
    ["❤️", "❤️"],
    // White space around the name is trimmed as Go's strings.TrimSpace does, U+00A0 and U+0085 included.
    [" x", "x"],
    ["x\u0085", "x"],
    ["　x ", "x"],
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
    ["　", "REQUIRED"],
    [undefined, "REQUIRED"],
    [42, "REQUIRED"],
    ["ệ".repeat(51), "TOO_LONG"],
    ["😀".repeat(51), "TOO_LONG"],
    // Control characters (Cc).
    ["Lan\nPhương", "INVALID_CHARACTERS"],
    ["Lan\rPhương", "INVALID_CHARACTERS"],
    ["Lan\tPhương", "INVALID_CHARACTERS"],
    ["Lan\u0000", "INVALID_CHARACTERS"],
    ["Lan\u007f", "INVALID_CHARACTERS"],
    ["Lan\u0085Phương", "INVALID_CHARACTERS"],
    ["a\u009fb", "INVALID_CHARACTERS"],
    // Line and paragraph separators.
    ["Lan Phương", "INVALID_CHARACTERS"],
    ["Lan Phương", "INVALID_CHARACTERS"],
    // Bidi controls (Cf).
    ["‮Lan", "INVALID_CHARACTERS"],
    ["a‪b", "INVALID_CHARACTERS"],
    ["a؜b", "INVALID_CHARACTERS"],
    ["a‎b", "INVALID_CHARACTERS"],
    ["Lan‏", "INVALID_CHARACTERS"],
    ["Lan⁦x", "INVALID_CHARACTERS"],
    ["a⁩b", "INVALID_CHARACTERS"],
    // Other invisible format characters (Cf), a tag character among them.
    ["​", "INVALID_CHARACTERS"],
    ["a​b", "INVALID_CHARACTERS"],
    ["⁠", "INVALID_CHARACTERS"],
    ["﻿a", "INVALID_CHARACTERS"],
    ["a­b", "INVALID_CHARACTERS"],
    ["Lan\u{e0041}", "INVALID_CHARACTERS"],
    // Other default-ignorable code points, and the blank Braille pattern.
    ["ㅤ", "INVALID_CHARACTERS"],
    ["aᅟb", "INVALID_CHARACTERS"],
    ["ﾠ", "INVALID_CHARACTERS"],
    ["a͏b", "INVALID_CHARACTERS"],
    ["⠀", "INVALID_CHARACTERS"],
    // Joiners alone show nothing.
    ["‍", "INVALID_CHARACTERS"],
    ["️‍", "INVALID_CHARACTERS"],
    // A lone surrogate, which user-service would get as invalid UTF-8.
    ["Lan\ud800", "INVALID_CHARACTERS"],
  ])("refuses %j with %s", (input, error) => {
    expect(checkDisplayName(input)).toEqual({ ok: false, error });
  });
});
