import * as z from "zod/mini";

// State of the login and register forms (useActionState with the actions of server/auth-actions.ts). Errors are codes
// the UI translates; nothing here is secret, so client components import it. The email and handle are sent back so a
// form posted without JavaScript keeps them; the password never is.

export type AuthFieldErrorCode = "INVALID_EMAIL" | "INVALID_PASSWORD" | "INVALID_HANDLE" | "HANDLE_ALREADY_TAKEN";

export type AuthFormErrorCode = "EMAIL_ALREADY_REGISTERED" | "INVALID_CREDENTIALS" | "RATE_LIMITED" | "UNAVAILABLE";

export interface AuthState {
  email: string;
  handle: string;
  fieldErrors: {
    email?: "INVALID_EMAIL";
    password?: "INVALID_PASSWORD";
    handle?: "INVALID_HANDLE" | "HANDLE_ALREADY_TAKEN";
  };
  formError: AuthFormErrorCode | null;
  // Set with RATE_LIMITED: seconds until the gateway takes another try, from its Retry-After.
  retryAfterSeconds: number | null;
}

export const initialAuthState: AuthState = {
  email: "",
  handle: "",
  fieldErrors: {},
  formError: null,
  retryAfterSeconds: null,
};

// The handle rules of user-service (docs/adr/0018-web-profiles-public-video-upload.md, section 1), checked in the
// browser and in the register action alike. Only ASCII A-Z is lowered: a Unicode lowering would turn the Kelvin sign
// into k, making two different inputs one handle, so any other character is left in place and fails the pattern.
export function normalizeHandle(value: string): string {
  return value.trim().replace(/[A-Z]/g, (letter) => letter.toLowerCase());
}

// 3 to 30 characters: a lowercase letter, then lowercase letters, digits or _.
const handlePattern = /^[a-z][a-z0-9_]{2,29}$/;
// The form of generated handles (u_ and 12 hex digits), which nobody may choose.
const generatedHandlePattern = /^u_[0-9a-f]{12}$/;

// A handle the user chose, normalized first; the web always sends one, so an empty field is an error here.
// zod/mini keeps this small in the login page's bundle.
export const chosenHandleSchema = z.string().check(
  z.overwrite(normalizeHandle),
  z.regex(handlePattern),
  z.refine((value) => !generatedHandlePattern.test(value)),
);
