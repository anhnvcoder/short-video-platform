// State of the login and register forms (useActionState with the actions of server/auth-actions.ts). Errors are codes
// the UI translates; nothing here is secret, so client components import it. The email is sent back so a form posted
// without JavaScript keeps it; the password never is.

export type AuthFieldErrorCode = "INVALID_EMAIL" | "INVALID_PASSWORD";

export type AuthFormErrorCode = "EMAIL_ALREADY_REGISTERED" | "INVALID_CREDENTIALS" | "RATE_LIMITED" | "UNAVAILABLE";

export interface AuthState {
  email: string;
  fieldErrors: { email?: "INVALID_EMAIL"; password?: "INVALID_PASSWORD" };
  formError: AuthFormErrorCode | null;
  // Set with RATE_LIMITED: seconds until the gateway takes another try, from its Retry-After.
  retryAfterSeconds: number | null;
}

export const initialAuthState: AuthState = { email: "", fieldErrors: {}, formError: null, retryAfterSeconds: null };
