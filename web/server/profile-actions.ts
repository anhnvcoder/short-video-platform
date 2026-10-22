"use server";

import { refresh } from "next/cache";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { z } from "zod";
import { checkDisplayName, type DisplayNameState } from "@/features/profile/display-name";
import { serverEnv } from "./env";
import { gatewayClient, retryAfterSeconds } from "./gateway";
import { bffServices } from "./runtime";
import { sessionCookieName } from "./session";

// Server Action of the display name form on /me (docs/adr/0018-web-profiles-public-video-upload.md, section 7), for
// useActionState; a form posted without JavaScript works the same. It is a public endpoint like every action: it checks
// its own input and the session itself, and proxy.ts has already checked the request's origin. The session's token
// stays here; expected failures come back as state.

// Above the gateway's own 3 s per backend call, so the gateway's 504 arrives before this gives up.
const updateTimeoutMs = 4000;

// Where an expired session goes: the login page, back to /me afterwards.
const loginTarget = `/login?next=${encodeURIComponent("/me")}`;

const problemCodeSchema = z.object({ code: z.string() });
const savedSchema = z.object({ display_name: z.string().min(1) });

function stateOf(value: string, patch: Partial<DisplayNameState>): DisplayNameState {
  return { value, fieldError: null, formError: null, retryAfterSeconds: null, saved: null, ...patch };
}

type Outcome = { kind: "state"; state: DisplayNameState } | { kind: "login" };

async function update(input: FormDataEntryValue | null): Promise<Outcome> {
  const typed = typeof input === "string" ? input : "";
  const checked = checkDisplayName(typed);
  if (!checked.ok) {
    return { kind: "state", state: stateOf(typed, { fieldError: checked.error }) };
  }
  const name = checked.value;

  // The cookie first: without one the user is logged out, whatever the session store's state.
  const sid = (await cookies()).get(sessionCookieName(serverEnv().secure))?.value;
  if (!sid) {
    return { kind: "login" };
  }
  const services = await bffServices().catch(() => null);
  if (!services) {
    return { kind: "state", state: stateOf(name, { formError: "UNAVAILABLE" }) };
  }
  const forwardedFor = (await headers()).get("x-forwarded-for");
  // Redis failing in the middle of the lookup is an answer for the form, not an error page.
  const access = await services.access.access(sid, forwardedFor).catch(() => null);
  if (!access) {
    return { kind: "state", state: stateOf(name, { formError: "UNAVAILABLE" }) };
  }
  if (access.kind === "none" || access.kind === "expired") {
    return { kind: "login" };
  }
  if (access.kind === "unavailable") {
    return access.status === 429
      ? {
          kind: "state",
          state: stateOf(name, { formError: "RATE_LIMITED", retryAfterSeconds: access.retryAfterSeconds ?? 1 }),
        }
      : { kind: "state", state: stateOf(name, { formError: "UNAVAILABLE" }) };
  }
  const { session } = access;

  let answer;
  try {
    answer = await gatewayClient(services.env.gatewayOrigin, session.access_token, forwardedFor).PATCH("/me", {
      body: { display_name: name },
      signal: AbortSignal.timeout(updateTimeoutMs),
    });
  } catch {
    return { kind: "state", state: stateOf(name, { formError: "UNAVAILABLE" }) };
  }
  const { data, error, response } = answer;
  if (response.ok) {
    // The stored name is what user-service answers; an answer without one still means the change went through.
    const saved = savedSchema.safeParse(data).data?.display_name ?? name;
    return { kind: "state", state: stateOf(saved, { saved }) };
  }
  if (response.status === 401) {
    // The gateway refuses a token the session just handed out: the session is of no use. Ending it keeps the login
    // page, which sends a logged-in visitor away, from sending the user straight back here.
    await services.access.end(sid, session, forwardedFor).catch(() => {
      // Redis is down: the session stays until its TTL, and the next request tries again.
    });
    return { kind: "login" };
  }
  if (response.status === 429) {
    return {
      kind: "state",
      state: stateOf(name, { formError: "RATE_LIMITED", retryAfterSeconds: retryAfterSeconds(response) }),
    };
  }
  if (response.status === 400 && problemCodeSchema.safeParse(error).data?.code === "INVALID_DISPLAY_NAME") {
    return { kind: "state", state: stateOf(name, { fieldError: "INVALID_DISPLAY_NAME" }) };
  }
  return { kind: "state", state: stateOf(name, { formError: "UNAVAILABLE" }) };
}

export async function updateDisplayNameAction(_previous: DisplayNameState, form: FormData): Promise<DisplayNameState> {
  const outcome = await update(form.get("display_name"));
  // Outside any try/catch: redirect() throws to hand control back to Next.
  if (outcome.kind === "login") {
    redirect(loginTarget);
  }
  if (outcome.state.saved !== null) {
    // The new name shows at once in this page and the side bar, which the server renders from GET /me.
    refresh();
  }
  return outcome.state;
}
