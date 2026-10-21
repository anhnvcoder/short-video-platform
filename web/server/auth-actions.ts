"use server";

import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { checkCredentials, failureState, safeNext, signIn } from "./auth";
import type { AuthState } from "./auth-state";
import { bffServices } from "./runtime";
import { sessionCookieName, sessionCookieOptions } from "./session";

// Server Actions of the login and register forms, for useActionState; a form posted without JavaScript works the same.
// Each action is a public endpoint: it checks its own input, and proxy.ts has already checked the request's origin.
// Expected failures come back as state; on success the action redirects (303) to the checked `next` field.

export async function loginAction(_previous: AuthState, form: FormData): Promise<AuthState> {
  const checked = checkCredentials({ email: form.get("email"), password: form.get("password") });
  if (!checked.ok) {
    return checked.state;
  }
  return startSession(checked.email, checked.password, form.get("next"));
}

// Registers, then logs in with the same credentials.
export async function registerAction(_previous: AuthState, form: FormData): Promise<AuthState> {
  const checked = checkCredentials({ email: form.get("email"), password: form.get("password") });
  if (!checked.ok) {
    return checked.state;
  }
  const services = await bffServices().catch(() => null);
  if (!services) {
    return failureState(checked.email, { ok: false, code: "UNAVAILABLE" });
  }
  const forwardedFor = (await headers()).get("x-forwarded-for");
  const registered = await services.gateway.register(checked.email, checked.password, forwardedFor);
  if (!registered.ok) {
    return failureState(checked.email, registered);
  }
  return startSession(checked.email, checked.password, form.get("next"));
}

async function startSession(email: string, password: string, next: FormDataEntryValue | null): Promise<AuthState> {
  const services = await bffServices().catch(() => null);
  if (!services) {
    return failureState(email, { ok: false, code: "UNAVAILABLE" });
  }
  const { secure, appOrigin } = services.env;
  const cookieStore = await cookies();
  const forwardedFor = (await headers()).get("x-forwarded-for");
  const result = await signIn(
    services,
    email,
    password,
    forwardedFor,
    cookieStore.get(sessionCookieName(secure))?.value,
  );
  if (!result.ok) {
    return result.state;
  }
  cookieStore.set(sessionCookieName(secure), result.sid, sessionCookieOptions(secure));
  // Outside any try/catch: redirect() throws to hand control back to Next.
  redirect(safeNext(next, appOrigin));
}
