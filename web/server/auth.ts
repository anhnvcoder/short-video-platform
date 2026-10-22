import "server-only";
import { z } from "zod";
import { chosenHandleSchema, normalizeHandle, type AuthState } from "./auth-state";
import type { AuthFailure } from "./gateway";
import type { BffServices } from "./runtime";

// Login, register and logout of the BFF (docs/adr/0016-web-client.md, section 5), apart from the Next request APIs so
// tests can drive them. server/auth-actions.ts and app/logout/route.ts wire them to cookies, headers and redirects.

// The gateway checks the same rules; checking here saves a round trip and shows the error on the field.
const credentialsSchema = z.object({
  email: z.string().trim().max(254).pipe(z.email()),
  password: z.string().min(8).max(128),
});

export interface CredentialsInput {
  email: FormDataEntryValue | null;
  password: FormDataEntryValue | null;
}

type Checked = { ok: true; email: string; password: string } | { ok: false; state: AuthState };

export function checkCredentials(input: CredentialsInput): Checked {
  const email = typeof input.email === "string" ? input.email.trim() : "";
  const parsed = credentialsSchema.safeParse({ email: input.email ?? "", password: input.password ?? "" });
  if (parsed.success) {
    return { ok: true, ...parsed.data };
  }
  const fields = new Set(parsed.error.issues.map((issue) => issue.path[0]));
  return {
    ok: false,
    state: {
      email,
      handle: "",
      fieldErrors: {
        ...(fields.has("email") ? { email: "INVALID_EMAIL" } : {}),
        ...(fields.has("password") ? { password: "INVALID_PASSWORD" } : {}),
      },
      formError: null,
      retryAfterSeconds: null,
    },
  };
}

export interface RegistrationInput extends CredentialsInput {
  handle: FormDataEntryValue | null;
}

type CheckedRegistration =
  { ok: true; email: string; password: string; handle: string } | { ok: false; state: AuthState };

// The credentials as for login, and the handle the user chose, sent to the gateway in its normalized form.
export function checkRegistration(input: RegistrationInput): CheckedRegistration {
  const credentials = checkCredentials(input);
  const handle = chosenHandleSchema.safeParse(typeof input.handle === "string" ? input.handle : "");
  if (credentials.ok && handle.success) {
    return { ...credentials, handle: handle.data };
  }
  const state: AuthState = credentials.ok
    ? { email: credentials.email, handle: "", fieldErrors: {}, formError: null, retryAfterSeconds: null }
    : credentials.state;
  state.handle = typeof input.handle === "string" ? normalizeHandle(input.handle) : "";
  if (!handle.success) {
    state.fieldErrors.handle = "INVALID_HANDLE";
  }
  return { ok: false, state };
}

export function failureState(email: string, failure: AuthFailure, handle = ""): AuthState {
  const state: AuthState = { email, handle, fieldErrors: {}, formError: null, retryAfterSeconds: null };
  if (failure.code === "INVALID_EMAIL") {
    state.fieldErrors.email = failure.code;
  } else if (failure.code === "INVALID_PASSWORD") {
    state.fieldErrors.password = failure.code;
  } else if (failure.code === "INVALID_HANDLE" || failure.code === "HANDLE_ALREADY_TAKEN") {
    state.fieldErrors.handle = failure.code;
  } else {
    state.formError = failure.code;
    state.retryAfterSeconds = failure.retryAfterSeconds ?? null;
  }
  return state;
}

// Where to go after login: a path of this app, else / (WEB-4). The check runs on the target actually returned, after
// the URL parser has resolved `..` and `%2e%2e`: `/a/..//evil.example` passes an origin check yet comes out as
// `//evil.example`, which a browser reads as another host. A target whose path starts with // or /\ (also once
// percent-decoded) or holds a control character is refused, and so is a raw value with a backslash or a control
// character, which the parser would otherwise drop or turn into a slash.
export function safeNext(next: FormDataEntryValue | string | null | undefined, appOrigin: string): string {
  if (typeof next !== "string" || !next.startsWith("/") || /[\\\x00-\x1f\x7f]/.test(next)) {
    return "/";
  }
  let url: URL;
  let decodedPath: string;
  try {
    url = new URL(next, appOrigin);
    decodedPath = decodeURIComponent(url.pathname);
  } catch {
    return "/";
  }
  if (url.origin !== appOrigin) {
    return "/";
  }
  for (const path of [url.pathname, decodedPath]) {
    if (path.startsWith("//") || path.startsWith("/\\") || /[\\\x00-\x1f\x7f]/.test(path)) {
      return "/";
    }
  }
  return url.pathname + url.search + url.hash;
}

export type SignInResult = { ok: true; sid: string } | { ok: false; state: AuthState };

// Logs in through the gateway and starts a session under a fresh sid; the session of oldSid, if any, ends first and
// its refresh token family is revoked, so a sid planted before login is worth nothing after it (session fixation).
export async function signIn(
  services: BffServices,
  email: string,
  password: string,
  forwardedFor: string | null,
  oldSid: string | undefined,
): Promise<SignInResult> {
  const { store, gateway } = services;
  const result = await gateway.login(email, password, forwardedFor);
  if (!result.ok) {
    return { ok: false, state: failureState(email, result) };
  }
  try {
    if (oldSid) {
      await signOut(services, oldSid, forwardedFor);
    }
    const { sid } = await store.create(result.userId, result.tokens);
    return { ok: true, sid };
  } catch {
    // No session could be stored: the new family is of no use to anyone.
    await gateway.logout(result.tokens.refresh_token, forwardedFor).catch(() => {});
    return { ok: false, state: failureState(email, { ok: false, code: "UNAVAILABLE" }) };
  }
}

// Revokes the session's refresh token family at the gateway (a failure is logged and the logout goes on) and deletes
// the session.
export async function signOut(services: BffServices, sid: string, forwardedFor: string | null): Promise<void> {
  const session = await services.store.get(sid);
  if (!session) {
    return;
  }
  try {
    await services.gateway.logout(session.refresh_token, forwardedFor);
  } catch {
    console.warn("gateway logout failed; deleting the session anyway");
  }
  await services.store.delete(sid);
}
