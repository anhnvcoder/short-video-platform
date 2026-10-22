import { createServer, type AddressInfo, type Socket } from "node:net";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { connectRedis, sessionRedis } from "./redis";

// The servers here are plain TCP servers the test opens on a port the system picks: no port is guessed, and no Redis
// is involved.

async function listen(onConnection: (socket: Socket) => void) {
  const server = createServer(onConnection);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  const close = () => new Promise<void>((resolve) => server.close(() => resolve()));
  return { port, close };
}

// A port that was just free: opened, then closed again, so a connection to it is refused.
async function closedPort(): Promise<number> {
  const { port, close } = await listen(() => {});
  await close();
  return port;
}

afterEach(() => {
  vi.restoreAllMocks();
});

afterAll(() => {
  vi.unstubAllEnvs();
});

describe("connecting to the session Redis", () => {
  it("fails at once when the first connection is refused, instead of retrying forever", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const started = Date.now();
    await expect(connectRedis(`redis://127.0.0.1:${await closedPort()}/15`, 2000)).rejects.toThrow(/ECONNREFUSED/);
    expect(Date.now() - started).toBeLessThan(1000);
  });

  it("gives up after the budget when the server accepts but never answers the handshake, and closes the socket", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    let closed: Promise<void> | undefined;
    const silent = await listen((socket) => {
      closed = new Promise((resolve) => socket.on("close", () => resolve()));
      // Reads the handshake and drops it; a socket nobody reads never sees the client hang up.
      socket.resume();
    });
    const started = Date.now();
    await expect(connectRedis(`redis://127.0.0.1:${silent.port}/15`, 200)).rejects.toThrow(
      "session redis: no connection within 200 ms",
    );
    expect(Date.now() - started).toBeGreaterThanOrEqual(190);
    expect(closed).toBeDefined();
    await closed;
    await silent.close();
  });

  it("sessionRedis starts over with a new connection on the next request after a failed one", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    let connections = 0;
    const resetting = await listen((socket) => {
      connections++;
      socket.destroy();
    });
    vi.stubEnv("GATEWAY_URL", "http://gateway.test");
    vi.stubEnv("REDIS_URL", `redis://127.0.0.1:${resetting.port}/15`);
    vi.stubEnv("APP_ORIGIN", "http://localhost:3001");
    vi.stubEnv("MEDIA_ORIGIN", "http://127.0.0.1:9000");
    vi.stubEnv("UPLOAD_ORIGIN", "http://127.0.0.1:9000");

    await expect(sessionRedis()).rejects.toThrow();
    await expect(sessionRedis()).rejects.toThrow();
    expect(connections).toBe(2);
    await resetting.close();
  });
});
