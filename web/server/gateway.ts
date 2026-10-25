import "server-only";
import createClient from "openapi-fetch";
import { z } from "zod";
import type { paths } from "@/gen/api";
import type { TokenSet } from "./session";

// Calls from the BFF to the gateway, typed from services/gateway/openapi.yaml (web/gen/api.d.ts). Every call goes to
// the one gateway origin of GATEWAY_URL; no caller can pass another host.
//
// X-Forwarded-For is passed on exactly as the web server received it, without adding a hop: in the cluster Envoy
// writes it and the gateway trusts one hop from the pod range the web pods share, so it reads the element Envoy wrote.
// Without the header none is sent.

export type GatewayClient = ReturnType<typeof createClient<paths>>;

// Above the gateway's own 3 s per backend call, so the gateway's 504 arrives before this gives up.
export const refreshTimeoutMs = 4000;
// Register and login hash a password (argon2id), which takes longer than the other calls.
const authTimeoutMs = 10_000;

export function gatewayHeaders(accessToken: string | null, forwardedFor: string | null): Record<string, string> {
  const headers: Record<string, string> = { Accept: "application/json, application/problem+json" };
  if (accessToken !== null) {
    headers.Authorization = `Bearer ${accessToken}`;
  }
  if (forwardedFor !== null) {
    headers["X-Forwarded-For"] = forwardedFor;
  }
  return headers;
}

// A typed client for server code that calls the gateway on behalf of the session's user.
export function gatewayClient(origin: string, accessToken: string | null, forwardedFor: string | null): GatewayClient {
  return createClient<paths>({ baseUrl: origin, headers: gatewayHeaders(accessToken, forwardedFor) });
}

const tokenSetSchema = z.object({
  access_token: z.string().min(1),
  expires_at: z.iso.datetime({ offset: true }),
  refresh_token: z.string().min(1),
  refresh_expires_at: z.iso.datetime({ offset: true }),
});

const problemCodeSchema = z.object({ code: z.string() });

// Reasons the login and register forms show, as codes the UI translates.
export type AuthFailureCode =
  | "INVALID_EMAIL"
  | "INVALID_PASSWORD"
  | "EMAIL_ALREADY_REGISTERED"
  | "INVALID_HANDLE"
  | "HANDLE_ALREADY_TAKEN"
  | "INVALID_CREDENTIALS"
  | "RATE_LIMITED"
  | "UNAVAILABLE";

export interface AuthFailure {
  ok: false;
  code: AuthFailureCode;
  retryAfterSeconds?: number;
}

export type LoginResult = { ok: true; userId: string; tokens: TokenSet } | AuthFailure;
export type RegisterResult = { ok: true } | AuthFailure;

export type RefreshResult =
  | { kind: "rotated"; tokens: TokenSet }
  // 401: the refresh token is used up, revoked, expired or unknown; the session is over.
  | { kind: "invalid" }
  | { kind: "rate-limited"; retryAfterSeconds: number }
  // Timeout, 5xx, a lost answer: the token may or may not have been rotated.
  | { kind: "unknown" };

// What the register form sends: the handle already normalized and checked.
export interface NewAccount {
  email: string;
  password: string;
  handle: string;
}

export interface AuthGateway {
  login(email: string, password: string, forwardedFor: string | null): Promise<LoginResult>;
  register(account: NewAccount, forwardedFor: string | null): Promise<RegisterResult>;
  // Gives up when `deadline` aborts, whether the answer has started to arrive or not.
  refresh(refreshToken: string, forwardedFor: string | null, deadline: AbortSignal): Promise<RefreshResult>;
  // Revokes the token's family; throws when the gateway did not confirm it.
  logout(refreshToken: string, forwardedFor: string | null): Promise<void>;
}

const knownFailures: Partial<Record<number, readonly AuthFailureCode[]>> = {
  400: ["INVALID_EMAIL", "INVALID_PASSWORD", "INVALID_HANDLE"],
  401: ["INVALID_CREDENTIALS"],
  409: ["EMAIL_ALREADY_REGISTERED", "HANDLE_ALREADY_TAKEN"],
};

// Whole seconds of a Retry-After header in seconds; a missing or odd header means one second.
export function retryAfterSeconds(response: Response): number {
  const seconds = Number(response.headers.get("retry-after"));
  return Number.isInteger(seconds) && seconds > 0 ? seconds : 1;
}

function authFailure(response: Response, body: unknown): AuthFailure {
  if (response.status === 429) {
    return { ok: false, code: "RATE_LIMITED", retryAfterSeconds: retryAfterSeconds(response) };
  }
  const code = problemCodeSchema.safeParse(body).data?.code;
  const expected = knownFailures[response.status];
  if (code && expected?.includes(code as AuthFailureCode)) {
    return { ok: false, code: code as AuthFailureCode };
  }
  return { ok: false, code: "UNAVAILABLE" };
}

// The user id is the subject of the access token. The token comes straight from the gateway over the trusted
// network, so its payload is read without checking the signature; the gateway checks it on every call.
export function subjectOf(accessToken: string): string | null {
  const payload = accessToken.split(".")[1];
  if (!payload) {
    return null;
  }
  try {
    const claims: unknown = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return z.object({ sub: z.uuid() }).safeParse(claims).data?.sub ?? null;
  } catch {
    return null;
  }
}

export function createAuthGateway(origin: string, options: { refreshTimeoutMs?: number } = {}): AuthGateway {
  const timeout = options.refreshTimeoutMs ?? refreshTimeoutMs;
  const client = (forwardedFor: string | null) => gatewayClient(origin, null, forwardedFor);

  return {
    async login(email, password, forwardedFor) {
      try {
        const { data, error, response } = await client(forwardedFor).POST("/auth/login", {
          body: { email, password },
          signal: AbortSignal.timeout(authTimeoutMs),
        });
        if (!response.ok) {
          return authFailure(response, error);
        }
        const tokens = tokenSetSchema.safeParse(data).data;
        const userId = tokens ? subjectOf(tokens.access_token) : null;
        return tokens && userId ? { ok: true, userId, tokens } : { ok: false, code: "UNAVAILABLE" };
      } catch {
        return { ok: false, code: "UNAVAILABLE" };
      }
    },

    async register({ email, password, handle }, forwardedFor) {
      try {
        // No display_name: user-service starts it as the handle.
        const { error, response } = await client(forwardedFor).POST("/auth/register", {
          body: { email, password, handle },
          signal: AbortSignal.timeout(authTimeoutMs),
        });
        return response.ok ? { ok: true } : authFailure(response, error);
      } catch {
        return { ok: false, code: "UNAVAILABLE" };
      }
    },

    async refresh(refreshToken, forwardedFor, deadline) {
      try {
        // The signal covers the whole call, connection and body: openapi-fetch reads the body before it returns.
        const { data, response } = await client(forwardedFor).POST("/auth/refresh", {
          body: { refresh_token: refreshToken },
          signal: AbortSignal.any([deadline, AbortSignal.timeout(timeout)]),
        });
        if (response.ok) {
          const tokens = tokenSetSchema.safeParse(data).data;
          return tokens ? { kind: "rotated", tokens } : { kind: "unknown" };
        }
        if (response.status === 401) {
          return { kind: "invalid" };
        }
        if (response.status === 429) {
          return { kind: "rate-limited", retryAfterSeconds: retryAfterSeconds(response) };
        }
        return { kind: "unknown" };
      } catch {
        return { kind: "unknown" };
      }
    },

    async logout(refreshToken, forwardedFor) {
      const { response } = await client(forwardedFor).POST("/auth/logout", {
        body: { refresh_token: refreshToken },
        signal: AbortSignal.timeout(timeout),
      });
      if (response.status !== 204) {
        throw new Error(`gateway logout answered ${response.status}`);
      }
    },
  };
}
