import { randomBytes } from "node:crypto";
import { createClient } from "redis";
import { afterAll, afterEach, beforeAll, beforeEach } from "vitest";

// Test access to the local Redis named by SVP_TEST_REDIS_URL (`make test` and `make web-check` set it). The local Redis
// is shared with other projects, so every URL but db 15 of 127.0.0.1:6379 (or localhost:6379) is refused before a
// command is sent, each test gets a random key prefix of its own, and only the keys under that prefix are deleted
// afterwards: never FLUSHDB, not even on db 15.

export const testRedisURL = process.env.SVP_TEST_REDIS_URL;

const allowedHosts = new Set(["127.0.0.1", "localhost"]);

export type TestRedis = ReturnType<typeof createClient>;

// Checks rawURL names db 15 of the local Redis. The error never repeats the URL: it may carry a password.
export function checkTestRedisURL(rawURL: string): void {
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    throw new Error("SVP_TEST_REDIS_URL is not a URL");
  }
  const port = url.port === "" ? "6379" : url.port;
  if (
    url.protocol !== "redis:" ||
    !allowedHosts.has(url.hostname) ||
    port !== "6379" ||
    url.pathname !== "/15" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new Error("SVP_TEST_REDIS_URL must point at redis://127.0.0.1:6379/15 or redis://localhost:6379/15");
  }
}

export function newTestPrefix(): string {
  return `svp:test:${randomBytes(8).toString("hex")}:`;
}

// Deletes every key under prefix, which holds only hex digits and colons, so it is safe in a MATCH pattern.
export async function deletePrefix(client: TestRedis, prefix: string): Promise<void> {
  for await (const keys of client.scanIterator({ MATCH: `${prefix}*`, COUNT: 100 })) {
    if (keys.length > 0) {
      await client.unlink(keys);
    }
  }
}

// Registers hooks that open one client for the file and give each test a fresh prefix; read both through the returned
// getters inside a test. Call it inside a `describe.skipIf(!testRedisURL)` block, so the tests skip without the
// variable.
export function useTestRedis(): { client: () => TestRedis; prefix: () => string } {
  let client: TestRedis | undefined;
  let prefix: string | undefined;

  beforeAll(async () => {
    if (!testRedisURL) {
      throw new Error("SVP_TEST_REDIS_URL is not set");
    }
    checkTestRedisURL(testRedisURL);
    client = createClient({ url: testRedisURL });
    client.on("error", () => {
      // Errors reach the commands that fail; the listener only keeps the client from crashing the run.
    });
    await client.connect();
  });
  beforeEach(() => {
    prefix = newTestPrefix();
  });
  afterEach(async () => {
    if (client && prefix) {
      await deletePrefix(client, prefix);
    }
    prefix = undefined;
  });
  afterAll(async () => {
    await client?.close();
  });

  return {
    client: () => {
      if (!client) {
        throw new Error("the test Redis client is not open");
      }
      return client;
    },
    prefix: () => {
      if (!prefix) {
        throw new Error("no test prefix outside a test");
      }
      return prefix;
    },
  };
}
