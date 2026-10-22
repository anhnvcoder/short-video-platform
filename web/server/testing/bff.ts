import { randomUUID } from "node:crypto";
import { http, HttpResponse } from "msw";
import { server } from "@/lib/test/msw-server";
import type { ServerEnv } from "../env";
import { createAuthGateway } from "../gateway";
import type { BffServices } from "../runtime";
import { SessionStore, type TokenSet } from "../session";
import { SessionAccess, type SessionAccessOptions } from "../session-access";
import type { TestRedis } from "./redis";

// Fakes for tests of the BFF: a gateway answered by MSW at a fixed origin, and the BFF's services on the test Redis.

export const gatewayOrigin = "http://gateway.test";

export const testEnv: ServerEnv = {
  gatewayOrigin,
  redisURL: "redis://127.0.0.1:6379/15",
  appOrigin: "http://localhost:3001",
  mediaOrigin: "http://127.0.0.1:9000",
  uploadOrigin: "http://127.0.0.1:9000",
  secure: false,
};

// An access token shaped like the gateway's JWT (it starts with eyJ, as every JWT does), with `sub` = userId.
export function fakeAccessToken(userId: string): string {
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "EdDSA", typ: "JWT" })}.${part({ sub: userId, jti: randomUUID() })}.c2lnbmF0dXJl`;
}

// A token set for userId whose access token expires in `accessExpiresInMs` (negative: already expired).
export function fakeTokens(userId: string, accessExpiresInMs = 3_600_000): TokenSet {
  return {
    access_token: fakeAccessToken(userId),
    expires_at: new Date(Date.now() + accessExpiresInMs).toISOString(),
    refresh_token: Buffer.from(randomUUID()).toString("base64url").slice(0, 43),
    refresh_expires_at: new Date(Date.now() + 14 * 24 * 3_600_000).toISOString(),
  };
}

export function accessTokenBody(tokens: TokenSet) {
  return { ...tokens, token_type: "Bearer" };
}

export function gatewayProblem(status: number, code: string, headers: Record<string, string> = {}) {
  return HttpResponse.json(
    { type: "about:blank", title: "", status, detail: "", code, trace_id: "0".repeat(32) },
    { status, headers: { "Content-Type": "application/problem+json", ...headers } },
  );
}

export function testServices(
  redis: TestRedis,
  prefix: string,
  options: SessionAccessOptions & { refreshTimeoutMs?: number; env?: Partial<ServerEnv> } = {},
): BffServices {
  const store = new SessionStore(redis, prefix);
  const gateway = createAuthGateway(gatewayOrigin, { refreshTimeoutMs: options.refreshTimeoutMs });
  return { env: { ...testEnv, ...options.env }, store, gateway, access: new SessionAccess(store, gateway, options) };
}

// Records every call to the gateway's /auth/logout and answers 204.
export function recordLogouts(): string[] {
  const tokens: string[] = [];
  server.use(
    http.post(`${gatewayOrigin}/auth/logout`, async ({ request }) => {
      tokens.push(((await request.json()) as { refresh_token: string }).refresh_token);
      return new HttpResponse(null, { status: 204 });
    }),
  );
  return tokens;
}
