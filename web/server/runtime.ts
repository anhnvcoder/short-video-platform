import "server-only";
import { serverEnv, type ServerEnv } from "./env";
import { createAuthGateway, type AuthGateway } from "./gateway";
import { sessionRedis } from "./redis";
import { SessionStore } from "./session";
import { SessionAccess } from "./session-access";

export interface BffServices {
  env: ServerEnv;
  store: SessionStore;
  gateway: AuthGateway;
  access: SessionAccess;
}

let services: Promise<BffServices> | undefined;

// The BFF's parts for this process, built on first use. One SessionAccess per process, so every request of the
// process shares its in-flight refreshes.
export function bffServices(): Promise<BffServices> {
  services ??= (async () => {
    const env = serverEnv();
    const store = new SessionStore(await sessionRedis());
    const gateway = createAuthGateway(env.gatewayOrigin);
    return { env, store, gateway, access: new SessionAccess(store, gateway) };
  })().catch((error: unknown) => {
    services = undefined;
    throw error;
  });
  return services;
}
