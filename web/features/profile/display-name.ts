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

// Control characters (C0, DEL, C1 with U+0085), line and paragraph separators, the bidi controls that would reorder the
// @handle and time shown after the name (WEB-18), and a lone surrogate, which is not text at all.
const forbidden = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]|\p{Cs}/u;

// NFC first: Vietnamese typed in decomposed form ("Phương" as 8 code points instead of 6, as a macOS keyboard may send
// it) is then counted as it reads, and user-service, which does not normalize, stores the composed form. The length is
// in code points (Go's runes), not UTF-16 units, so an emoji counts once.
export const displayNameSchema = z.string().check(
  z.overwrite((value) => value.normalize("NFC").trim()),
  z.minLength(1, { error: "REQUIRED" }),
  z.refine((value) => Array.from(value).length <= maxDisplayNameLength, { error: "TOO_LONG" }),
  z.refine((value) => !forbidden.test(value), { error: "INVALID_CHARACTERS" }),
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
