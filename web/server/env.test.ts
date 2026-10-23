import { describe, expect, it } from "vitest";
import { parseServerEnv } from "./env";

const valid = {
  GATEWAY_URL: "http://gateway:8080",
  REDIS_URL: "redis://host.docker.internal:6379/9",
  APP_ORIGIN: "http://localhost:3001",
  MEDIA_ORIGIN: "http://127.0.0.1:9000",
  UPLOAD_ORIGIN: "http://127.0.0.1:9000",
};

describe("parseServerEnv", () => {
  it("reads the compose values; http on localhost is not secure", () => {
    expect(parseServerEnv(valid)).toEqual({
      gatewayOrigin: "http://gateway:8080",
      redisURL: "redis://host.docker.internal:6379/9",
      appOrigin: "http://localhost:3001",
      mediaOrigin: "http://127.0.0.1:9000",
      uploadOrigin: "http://127.0.0.1:9000",
      secure: false,
      sentryDsn: null,
      sentryEnvironment: "local",
      buildId: undefined,
    });
  });

  it("reads the error tracker's DSN, environment and the build id", () => {
    const env = parseServerEnv({
      ...valid,
      SENTRY_DSN: "http://0123abcd@glitchtip:8000/1",
      SENTRY_ENVIRONMENT: "k3d",
      SVP_BUILD_ID: "dev-0123456789ab",
    });
    expect(env).toMatchObject({
      sentryDsn: "http://0123abcd@glitchtip:8000/1",
      sentryEnvironment: "k3d",
      buildId: "dev-0123456789ab",
    });
  });

  // Compose passes `${SENTRY_DSN:-}`: empty is the same as unset, reporting off.
  it("treats empty optional variables as unset", () => {
    expect(parseServerEnv({ ...valid, SENTRY_DSN: "", SENTRY_ENVIRONMENT: "", SVP_BUILD_ID: "" })).toMatchObject({
      sentryDsn: null,
      sentryEnvironment: "local",
      buildId: undefined,
    });
  });

  it("marks an https app origin secure", () => {
    expect(parseServerEnv({ ...valid, APP_ORIGIN: "https://svp.localhost:8443" }).secure).toBe(true);
  });

  it("names every missing variable", () => {
    expect(() => parseServerEnv({})).toThrow(
      /GATEWAY_URL is required.*REDIS_URL is required.*APP_ORIGIN.*MEDIA_ORIGIN.*UPLOAD_ORIGIN is required/,
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
    ["UPLOAD_ORIGIN", ""],
    ["UPLOAD_ORIGIN", "http://127.0.0.1:9000/uploads"],
    ["UPLOAD_ORIGIN", "http://127.0.0.1:9000/"],
    ["UPLOAD_ORIGIN", "ftp://127.0.0.1:9000"],
    ["UPLOAD_ORIGIN", "ws://127.0.0.1:9000"],
    ["UPLOAD_ORIGIN", "http://minio:9000"],
    ["UPLOAD_ORIGIN", "http://s3.example.com"],
    ["UPLOAD_ORIGIN", "http://127.0.0.2:9000"],
    ["REDIS_URL", "http://127.0.0.1:6379/9"],
    ["SENTRY_DSN", "http://glitchtip:8000/1"],
    ["SENTRY_DSN", "http://key@glitchtip:8000"],
    ["SENTRY_DSN", "http://key@glitchtip:8000/api/1/envelope/"],
    ["SENTRY_DSN", "http://key:secret@glitchtip:8000/1"],
    ["SENTRY_DSN", "ftp://key@glitchtip/1"],
    ["SENTRY_DSN", "not a dsn"],
    ["SENTRY_ENVIRONMENT", "K3D prod"],
    ["SVP_BUILD_ID", "a/b"],
  ])("refuses %s=%s", (name, value) => {
    expect(() => parseServerEnv({ ...valid, [name]: value })).toThrow(new RegExp(`${name} must`));
  });

  it.each(["https://s3.svp.localhost:8443", "http://localhost:9000", "http://[::1]:9000"])(
    "accepts UPLOAD_ORIGIN=%s",
    (value) => {
      expect(parseServerEnv({ ...valid, UPLOAD_ORIGIN: value }).uploadOrigin).toBe(value);
    },
  );

  // "http:" and "http://" are not URLs: the scheme check must not run on them, or `new URL` throws a TypeError that
  // names no variable and carries the value.
  it.each([
    ["APP_ORIGIN", "http:"],
    ["APP_ORIGIN", "http://"],
    ["UPLOAD_ORIGIN", "http:"],
    ["UPLOAD_ORIGIN", "http://"],
  ])("refuses %s=%s naming the variable once, without the value", (name, value) => {
    let error: unknown;
    try {
      parseServerEnv({ ...valid, [name]: value });
    } catch (caught) {
      error = caught;
    }
    expect(error).toBeInstanceOf(Error);
    expect(error).not.toBeInstanceOf(TypeError);
    const { message } = error as Error;
    expect(message).toBe(`invalid web server environment: ${name} must be an http(s) origin without a path`);
  });

  it("never repeats a value in its error", () => {
    const secret = "s3cret-pw";
    expect(() => parseServerEnv({ ...valid, REDIS_URL: `http://svp:${secret}@redis:6379/9` })).toThrow(
      expect.objectContaining({ message: expect.not.stringContaining(secret) }),
    );
    expect(() => parseServerEnv({ ...valid, SENTRY_DSN: `http://${secret}@glitchtip:8000/x` })).toThrow(
      expect.objectContaining({ message: expect.not.stringContaining(secret) }),
    );
  });
});
