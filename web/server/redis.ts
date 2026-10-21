import "server-only";
import { createClient } from "redis";
import { serverEnv } from "./env";

export type Redis = ReturnType<typeof createClient>;

// How long a request waits for the first connection, TCP connect and handshake together.
const connectBudgetMs = 2000;

let connecting: Promise<Redis> | undefined;

// The process's one client to the session database, connected on first use. A first connection that fails or takes
// longer than connectBudgetMs fails the requests waiting on it (503, UNAVAILABLE) and the next request starts over
// with a new client. Once connected, commands fail at once while the connection is down instead of queueing behind
// it, so a Redis outage answers requests with an error rather than holding them open; the client reconnects by itself.
export function sessionRedis(): Promise<Redis> {
  connecting ??= connectRedis(serverEnv().redisURL, connectBudgetMs).catch((error: unknown) => {
    connecting = undefined;
    throw error;
  });
  return connecting;
}

export async function connectRedis(url: string, budgetMs: number): Promise<Redis> {
  let connected = false;
  const client: Redis = createClient({
    url,
    disableOfflineQueue: true,
    socket: {
      connectTimeout: budgetMs,
      // By default the client retries a failed first connection forever and connect() never settles. Give up at once
      // instead; after the first connection, back off up to 2 s between attempts as the default strategy does.
      reconnectStrategy: (retries) => (connected ? Math.min(2 ** retries * 50, 2000) : false),
    },
  });
  client.on("error", (error: unknown) => {
    // The message of a connection error names the host and port only, never the URL with its password.
    console.error("session redis error:", error instanceof Error ? error.message : "unknown error");
  });
  try {
    // connectTimeout bounds the TCP connect only; a server that accepts and never answers the handshake would hold
    // connect() open.
    await withTimeout(client.connect(), budgetMs, "no connection");
  } catch (error) {
    client.destroy();
    throw error;
  }
  connected = true;
  return client;
}

// Rejects when `operation` has not settled within ms; the operation itself goes on, and its outcome is dropped.
export async function withTimeout<T>(operation: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timedOut = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`session redis: ${what} within ${ms} ms`)), ms);
  });
  try {
    return await Promise.race([operation, timedOut]);
  } finally {
    clearTimeout(timer);
  }
}
