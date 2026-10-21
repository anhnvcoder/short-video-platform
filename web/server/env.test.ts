import { describe, expect, it } from "vitest";
import { parseServerEnv } from "./env";

const valid = {
  GATEWAY_URL: "http://gateway:8080",
  REDIS_URL: "redis://host.docker.internal:6379/9",
  APP_ORIGIN: "http://localhost:3001",
  MEDIA_ORIGIN: "http://127.0.0.1:9000",
};

describe("parseServerEnv", () => {
  it("reads the compose values; http on localhost is not secure", () => {
    expect(parseServerEnv(valid)).toEqual({
      gatewayOrigin: "http://gateway:8080",
      redisURL: "redis://host.docker.internal:6379/9",
      appOrigin: "http://localhost:3001",
      mediaOrigin: "http://127.0.0.1:9000",
      secure: false,
    });
  });

  it("marks an https app origin secure", () => {
    expect(parseServerEnv({ ...valid, APP_ORIGIN: "https://svp.localhost:8443" }).secure).toBe(true);
  });

  it("names every missing variable", () => {
    expect(() => parseServerEnv({})).toThrow(
      /GATEWAY_URL is required.*REDIS_URL is required.*APP_ORIGIN.*MEDIA_ORIGIN/,
    );
  });

  it.each([
    ["APP_ORIGIN", "http://127.0.0.1:3001"],
    ["APP_ORIGIN", "http://example.com"],
    ["APP_ORIGIN", "http://localhost:3001/"],
    ["APP_ORIGIN", "https://svp.localhost:8443/app"],
    ["GATEWAY_URL", "ftp://gateway"],
    ["GATEWAY_URL", "http://user:pw@gateway:8080"],
    ["MEDIA_ORIGIN", "not a url"],
    ["REDIS_URL", "http://127.0.0.1:6379/9"],
  ])("refuses %s=%s", (name, value) => {
    expect(() => parseServerEnv({ ...valid, [name]: value })).toThrow(new RegExp(`${name} must`));
  });

  it("never repeats a value in its error", () => {
    const secret = "s3cret-pw";
    expect(() => parseServerEnv({ ...valid, REDIS_URL: `http://svp:${secret}@redis:6379/9` })).toThrow(
      expect.objectContaining({ message: expect.not.stringContaining(secret) }),
    );
  });
});
