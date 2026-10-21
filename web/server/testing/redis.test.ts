import { describe, expect, it } from "vitest";
import { checkTestRedisURL, deletePrefix, newTestPrefix, testRedisURL, useTestRedis } from "./redis";

describe("checkTestRedisURL", () => {
  it.each([
    ["db 0", "redis://127.0.0.1:6379/0"],
    ["db 5", "redis://127.0.0.1:6379/5"],
    ["db 7", "redis://127.0.0.1:6379/7"],
    ["session db 9", "redis://127.0.0.1:6379/9"],
    ["no db", "redis://127.0.0.1:6379"],
    ["db overridden by query", "redis://127.0.0.1:6379/15?database=0"],
    ["other host", "redis://10.0.0.1:6379/15"],
    ["compose host", "redis://host.docker.internal:6379/15"],
    ["other port", "redis://127.0.0.1:6380/15"],
    ["tls", "rediss://127.0.0.1:6379/15"],
    ["unix socket", "unix:///tmp/redis.sock"],
    ["not a URL", "127.0.0.1:6379/15"],
  ])("refuses %s", (_name, url) => {
    expect(() => checkTestRedisURL(url)).toThrow(/SVP_TEST_REDIS_URL/);
  });

  it("does not repeat a password in its error", () => {
    expect(() => checkTestRedisURL("redis://svp:s3cret-pw@10.0.0.1:6379/15")).toThrow(
      expect.objectContaining({ message: expect.not.stringContaining("s3cret-pw") }),
    );
  });

  it.each(["redis://127.0.0.1:6379/15", "redis://localhost:6379/15", "redis://127.0.0.1/15"])("accepts %s", (url) => {
    expect(() => checkTestRedisURL(url)).not.toThrow();
  });
});

describe("newTestPrefix", () => {
  it("is a fresh svp:test: prefix each time", () => {
    const a = newTestPrefix();
    expect(a).toMatch(/^svp:test:[0-9a-f]{16}:$/);
    expect(newTestPrefix()).not.toBe(a);
  });
});

describe.skipIf(!testRedisURL)("deletePrefix on the test Redis", () => {
  const redis = useTestRedis();

  it("deletes more than one SCAN page under its prefix and nothing else", async () => {
    const client = redis.client();
    const inner = newTestPrefix();
    const kept = `${redis.prefix()}kept`;
    await client.set(kept, "1", { expiration: { type: "EX", value: 60 } });
    const multi = client.multi();
    for (let i = 0; i < 250; i++) {
      multi.set(`${inner}k${i}`, "1", { expiration: { type: "EX", value: 60 } });
    }
    await multi.exec();

    await deletePrefix(client, inner);

    expect(await client.keys(`${inner}*`)).toEqual([]);
    expect(await client.exists(kept)).toBe(1);
  });
});
