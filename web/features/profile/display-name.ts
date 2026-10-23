import * as z from "zod/mini";

// The display name rules of user-service (docs/adr/0018-web-profiles-public-video-upload.md, section 2) and the state
// of the form that changes it (useActionState with server/profile-actions.ts). Nothing here is secret: the form checks
// in the browser with the same schema the action checks on the server. zod/mini keeps it small in the page's bundle.

// Why the name was refused, as codes the form translates. INVALID_DISPLAY_NAME is user-service refusing a name this
// check let through.
export type DisplayNameError = "REQUIRED" | "TOO_LONG" | "INVALID_CHARACTERS" | "INVALID_DISPLAY_NAME";

export type DisplayNameFormError = "RATE_LIMITED" | "UNAVAILABLE";

export interface DisplayNameState {
  // The name as last sent, so a form posted without JavaScript keeps it; null before the first answer.
  value: string | null;
  fieldError: DisplayNameError | null;
  formError: DisplayNameFormError | null;
  // Set with RATE_LIMITED: seconds until the gateway takes another try, from its Retry-After.
  retryAfterSeconds: number | null;
  // The name user-service stored, after a change went through.
  saved: string | null;
}

export const initialDisplayNameState: DisplayNameState = {
  value: null,
  fieldError: null,
  formError: null,
  retryAfterSeconds: null,
  saved: null,
};

export const maxDisplayNameLength = 50;

// The rules of user-service, character by character (normalizeDisplayName in
// services/user-service/internal/server/profile.go); user-service still decides, this only answers early. Refused:
//   - control characters (Cc), which break lines in the UI, and the line and paragraph separators U+2028, U+2029;
//   - format characters (Cf): the bidi controls that would reorder the @handle and time shown after the name (WEB-18),
//     and invisible ones such as U+200B, U+2060, U+FEFF, the soft hyphen and the tag characters;
//   - every other default-ignorable code point (the Hangul fillers U+115F, U+1160, U+3164, U+FFA0, the combining
//     grapheme joiner U+034F) and the blank Braille pattern U+2800: they render as nothing, so a name that looks empty
//     would pass the trim;
//   - a lone surrogate, which is not text at all (user-service refuses invalid UTF-8).
// The tables are the browser's Unicode version, user-service's are Go's: a code point new in one of them may be judged
// apart, and then user-service's answer (INVALID_DISPLAY_NAME) is the one shown.
const forbidden = /^[\p{Cc}\p{Cf}\p{Default_Ignorable_Code_Point}\p{Cs}\u2028\u2029\u2800]$/u;
// The invisible characters emoji need: the zero width joiner builds sequences such as a family, the variation
// selectors pick the emoji form of a symbol. They are allowed although they are Cf or default-ignorable, but they are
// not visible, so a name of joiners alone is refused.
const emojiJoiner = /^[\u200d\p{Variation_Selector}]$/u;
const space = /^\p{White_Space}$/u;
// What Go's strings.TrimSpace trims, which is not String.prototype.trim: U+0085 is trimmed here, U+FEFF is not (it is
// refused instead).
const surroundingSpace = /^\p{White_Space}+|\p{White_Space}+$/gu;

// Allowed characters only, and at least one that shows.
function hasOnlyAllowedCharacters(value: string): boolean {
  let visible = false;
  for (const char of value) {
    if (emojiJoiner.test(char)) {
      continue;
    }
    if (forbidden.test(char)) {
      return false;
    }
    if (!space.test(char)) {
      visible = true;
    }
  }
  return visible;
}

// NFC first: Vietnamese typed in decomposed form ("Phương" as 8 code points instead of 6, as a macOS keyboard may send
// it) is then counted as it reads, and user-service, which does not normalize, stores the composed form. The length is
// in code points (Go's runes), not UTF-16 units, so an emoji counts once.
export const displayNameSchema = z.string().check(
  z.overwrite((value) => value.normalize("NFC").replace(surroundingSpace, "")),
  z.minLength(1, { error: "REQUIRED" }),
  z.refine((value) => Array.from(value).length <= maxDisplayNameLength, { error: "TOO_LONG" }),
  z.refine(hasOnlyAllowedCharacters, { error: "INVALID_CHARACTERS" }),
);

export type CheckedDisplayName = { ok: true; value: string } | { ok: false; error: DisplayNameError };

// The name to send, or the first rule it breaks. Anything but a string (a missing form field) is an empty name.
export function checkDisplayName(input: unknown): CheckedDisplayName {
  const parsed = displayNameSchema.safeParse(typeof input === "string" ? input : "");
  if (parsed.success) {
    return { ok: true, value: parsed.data };
  }
  const code = parsed.error.issues[0]?.message;
  return { ok: false, error: code === "TOO_LONG" || code === "INVALID_CHARACTERS" ? code : "REQUIRED" };
}
