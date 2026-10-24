import type { ErrorEvent } from "@sentry/nextjs";
import { describe, expect, it, vi } from "vitest";
import { scrubBreadcrumb, scrubEvent, scrubString } from "./scrub";

const origins = { mediaOrigin: "http://127.0.0.1:9000", uploadOrigin: "https://s3.svp.localhost:8443" };
// 32 random bytes in base64url, like a session id or a refresh token.
const sid = Buffer.alloc(32, 7).toString("base64url");
const jwt = `eyJhbGciOiJFZERTQSJ9.${Buffer.from('{"sub":"u1"}').toString("base64url")}.c2lnbmF0dXJl`;

describe("scrubString", () => {
  it.each([
    ["an email", "no user minh.anh+svp@example.com.vn here", "no user [redacted] here"],
    [
      "the input a validation error repeats",
      'handle: "minh@example.com" is invalid',
      'handle: "[redacted]" is invalid',
    ],
    ["a JWT", `bearer ${jwt} refused`, "bearer [redacted] refused"],
    ["a session id or refresh token", `session ${sid} gone`, "session [redacted] gone"],
    ["the next of a login URL", "redirect to /login?next=/v/0b1c2d3e then", "redirect to /login then"],
    [
      "a presigned upload's signature",
      "POST https://s3.svp.localhost:8443/uploads/k?X-Amz-Credential=AKIA%2F1&X-Amz-Signature=abc failed",
      "POST https://s3.svp.localhost:8443/uploads/k failed",
    ],
    [
      "a query at the end of a frame",
      `at f (https://svp.localhost:8443/v/x?next=/me:3:4)`,
      "at f (https://svp.localhost:8443/v/x:3:4)",
    ],
    [
      "a chunk's deployment id",
      "at https://svp.localhost:8443/_next/static/chunks/a.js?dpl=dev-1:1:2",
      "at https://svp.localhost:8443/_next/static/chunks/a.js:1:2",
    ],
    ["an email that is the whole string", "minh@example.com", "[redacted]"],
    ["two emails side by side", "a@b.io c@d.io,e@f.io", "[redacted] [redacted],[redacted]"],
    ["an email right after another one's domain", "minh@example.co.1x@evil.com", "[redacted][redacted]"],
    ["an email with dots, a plus and sub-domains", "first.last+tag@mail.sub.example.co.uk", "[redacted]"],
    [
      "an email in a URL's path",
      "GET https://svp.localhost:8443/u/minh@example.com/videos failed",
      "GET https://svp.localhost:8443/u/[redacted]/videos failed",
    ],
    ["an email in a URL's query", "redirect to /login?email=minh@example.com", "redirect to /login"],
    ["an email after mailto", "mailto:minh@example.com", "mailto:[redacted]"],
    ["an email among Unicode text", "Lỗi của minh@example.com: sai", "Lỗi của [redacted]: sai"],
    ["a JWT that starts inside a run", `Bearer${jwt}`, "Bearer[redacted]"],
    ["a JWT in the parts after a run without one", `a.b.${jwt}`, "a.b.[redacted]"],
    ["a JWT right after another one", `${jwt}.${jwt}`, "[redacted].[redacted]"],
  ])("redacts %s", (_case, input, output) => {
    expect(scrubString(input)).toBe(output);
  });

  it.each([
    ["a 42-character run", "a".repeat(42)],
    ["a 44-character run", "a".repeat(44)],
    ["a UUID", "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"],
    ["a question", "Is the gateway up? No"],
    ["a chunk path", "/_next/static/chunks/0khh50nt3ldfz.js"],
    ["a mention and a host without a top-level domain", "@minh wrote to minh@localhost"],
  ])("keeps %s", (_case, input) => {
    expect(scrubString(input)).toBe(input);
  });

  it("keeps a run of 1 KiB and redacts a longer one whole, an address inside it too", () => {
    const run = `/${"a".repeat(1023)}`;
    expect(scrubString(`at ${run} end`)).toBe(`at ${run} end`);
    expect(scrubString(`at ${run}b end`)).toBe("at [redacted] end");
    expect(scrubString(`${"a.".repeat(4000)}minh@example.com ${"a.".repeat(4000)}`)).toBe("[redacted] [redacted]");
  });

  // Each pattern backtracks: its cost grows with the square of the run it reads, so none may read a long one.
  it("cuts a long run before any pattern reads it", () => {
    // Every match of a regular expression (replace, split, test, match) goes through exec once it is replaced.
    const exec = vi.spyOn(RegExp.prototype, "exec");
    // The worst case of the email pattern: a 16 KB run of local-part characters without an "@".
    const clean = scrubString(`user minh@example.com ${"a.".repeat(8000)} end`);
    const longReaders = new Set(
      exec.mock.contexts.filter((_pattern, i) => String(exec.mock.calls[i]?.[0]).length > 1024),
    );
    exec.mockRestore();
    expect(clean).toBe("user [redacted] [redacted] end");
    // The cut alone reads the whole text.
    expect(longReaders.size).toBe(1);
  });
});

// The email pattern used before, whose cost grew with the square of a run's length: the reference the current one must
// match exactly, so that no address it redacted gets through.
const quadraticEmailPattern = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;

describe("scrubString's email pattern", () => {
  it("redacts exactly what the quadratic pattern redacted", () => {
    // A fixed seed keeps the cases the same on every run. No "?", "eyJ" or run of 43 token characters, so that only
    // the email pattern changes these strings.
    let seed = 1;
    const random = (n: number) => {
      seed = (seed * 1103515245 + 12345) % 2 ** 31;
      return seed % n;
    };
    const alphabet = ["a", "b", "c", "o", "m", "1", ".", "-", "_", "+", "%", "@", "@", " ", "/", ",", "é"];
    for (let i = 0; i < 20000; i++) {
      const input = Array.from({ length: 1 + random(30) }, () => alphabet[random(alphabet.length)]).join("");
      expect(scrubString(input), input).toBe(input.replace(quadraticEmailPattern, "[redacted]"));
    }
  });

  // The browser's reports are unauthenticated and every run up to 1 KiB reaches this pattern. The same amount of text
  // in runs of 1 KiB and in runs of 32 characters: a linear pattern takes about as long on both, the quadratic one
  // about 32 times longer on the long runs. Comparing the two on one machine keeps the check independent of its speed.
  it.each([
    ["local-part characters without an @", (n: number) => "a".repeat(n)],
    ["dots between local-part characters", (n: number) => "a.".repeat(n / 2)],
    ["an @ before a domain without a top-level domain", (n: number) => `${"a".repeat(n / 2 - 1)}@${"a".repeat(n / 2)}`],
  ])("takes linear time on %s", (_case, run) => {
    const text = (runLength: number) => Array.from({ length: 65536 / runLength }, () => run(runLength)).join(" ");
    const fastest = (input: string) => {
      let best = Infinity;
      for (let i = 0; i < 5; i++) {
        const start = performance.now();
        scrubString(input);
        best = Math.min(best, performance.now() - start);
      }
      return best;
    };
    const short = fastest(text(32));
    const long = fastest(text(1024));
    expect(long / short).toBeLessThan(4);
  });
});

// The JWT pattern used before, whose cost grew with the square of a run's length: the reference the current one must
// match exactly, so that no token it redacted gets through.
const quadraticJwtPattern = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g;

describe("scrubString's JWT pattern", () => {
  it("redacts exactly what the quadratic pattern redacted", () => {
    // A fixed seed keeps the cases the same on every run. No "?", "@" or run of 43 token characters, so that only the
    // JWT pattern changes these strings.
    let seed = 1;
    const random = (n: number) => {
      seed = (seed * 1103515245 + 12345) % 2 ** 31;
      return seed % n;
    };
    const alphabet = ["eyJ", "eyJ", "e", "y", "J", "a", "1", "-", "_", ".", ".", " ", "/", "é"];
    for (let i = 0; i < 20000; i++) {
      const input = Array.from({ length: 1 + random(12) }, () => alphabet[random(alphabet.length)]).join("");
      expect(scrubString(input), input).toBe(input.replace(quadraticJwtPattern, "[redacted]"));
    }
  });

  // The same amount of text in runs of 1 KiB and in runs of 32 characters, as for the email pattern above.
  it.each([
    ["eyJ repeated without a dot", (n: number) => "eyJ".repeat(Math.floor(n / 3))],
    [
      "eyJ repeated around a single dot",
      (n: number) => `${"eyJ".repeat(Math.floor(n / 6))}.${"eyJ".repeat(Math.floor(n / 6))}`,
    ],
  ])("takes linear time on %s", (_case, run) => {
    const text = (runLength: number) => Array.from({ length: 65536 / runLength }, () => run(runLength)).join(" ");
    const fastest = (input: string) => {
      let best = Infinity;
      for (let i = 0; i < 5; i++) {
        const start = performance.now();
        scrubString(input);
        best = Math.min(best, performance.now() - start);
      }
      return best;
    };
    const short = fastest(text(32));
    const long = fastest(text(1024));
    expect(long / short).toBeLessThan(4);
  });
});

function serverEvent(): ErrorEvent {
  return {
    type: undefined,
    message: "login failed for minh@example.com",
    exception: { values: [{ type: "Error", value: `refresh ${sid} rejected` }] },
    request: {
      url: "http://localhost:3001/login?next=/me",
      method: "POST",
      headers: { cookie: `svp_sid=${sid}`, authorization: `Bearer ${jwt}` },
      cookies: { svp_sid: sid },
      data: '{"password":"hunter2"}',
      query_string: "next=/me",
      env: { REMOTE_ADDR: "10.42.0.7" },
    },
    user: { id: "u1", email: "minh@example.com", ip_address: "10.42.0.7" },
    server_name: "web-7d9f",
    extra: { form: { password: "hunter2" } },
    modules: { next: "16.4.2" },
    sdkProcessingMetadata: { normalizedRequest: { headers: { cookie: `svp_sid=${sid}` } } },
    tags: { route: "/login", note: "minh@example.com" },
    contexts: { nextjs: { request_path: "/login?next=/me" } },
    fingerprint: ["{{ default }}", jwt],
  };
}

describe("scrubEvent", () => {
  it("keeps only the request's URL, without its query", () => {
    expect(scrubEvent(serverEvent(), origins).request).toEqual({ url: "http://localhost:3001/login" });
  });

  it("drops the user, the host name, extra data, modules and what the SDK kept for itself", () => {
    const clean = scrubEvent(serverEvent(), origins);
    expect(clean).not.toHaveProperty("user");
    expect(clean).not.toHaveProperty("server_name");
    expect(clean).not.toHaveProperty("extra");
    expect(clean).not.toHaveProperty("modules");
    expect(clean).not.toHaveProperty("sdkProcessingMetadata");
  });

  it("redacts every remaining string", () => {
    const clean = scrubEvent(serverEvent(), origins);
    const text = JSON.stringify(clean);
    for (const secret of ["minh@example.com", sid, jwt, "hunter2", "10.42.0.7", "next=/me"]) {
      expect(text).not.toContain(secret);
    }
    expect(clean.message).toBe("login failed for [redacted]");
    expect(clean.exception?.values?.[0]?.value).toBe("refresh [redacted] rejected");
    expect(clean.tags).toEqual({ route: "/login", note: "[redacted]" });
    expect(clean.contexts).toEqual({ nextjs: { request_path: "/login" } });
  });

  it("scrubs breadcrumbs with the breadcrumb rules", () => {
    const clean = scrubEvent(
      {
        ...serverEvent(),
        breadcrumbs: [
          { category: "fetch", data: { url: "http://127.0.0.1:9000/media/hls/v/master.m3u8", status_code: 200 } },
          { category: "console", message: "deleting the session failed at logout" },
        ],
      },
      origins,
    );
    expect(clean.breadcrumbs).toEqual([
      { category: "fetch", data: { status_code: 200 } },
      { category: "console", message: "deleting the session failed at logout" },
    ]);
  });
});

describe("scrubBreadcrumb", () => {
  it.each([
    ["fetch", "http://127.0.0.1:9000/media/thumbs/v.jpg"],
    ["xhr", "https://s3.svp.localhost:8443/uploads?X-Amz-Signature=abc"],
  ])("drops the URL of a %s to storage", (category, url) => {
    expect(scrubBreadcrumb({ category, data: { url, method: "GET" } }, origins)).toEqual({
      category,
      data: { method: "GET" },
    });
  });

  it("keeps the URL of another request, without its query", () => {
    expect(
      scrubBreadcrumb({ category: "fetch", data: { url: "http://gateway:8080/feed/explore?cursor=abc" } }, origins),
    ).toEqual({ category: "fetch", data: { url: "http://gateway:8080/feed/explore" } });
  });

  it("redacts a console message's personal data", () => {
    expect(scrubBreadcrumb({ category: "console", message: `token ${jwt} for a@b.io` }, origins)).toEqual({
      category: "console",
      message: "token [redacted] for [redacted]",
      data: undefined,
    });
  });
});
