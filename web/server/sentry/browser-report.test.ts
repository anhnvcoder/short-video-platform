import { describe, expect, it, vi } from "vitest";
import { browserEvent, browserReportSchema, parseStack, routeTemplate, type BrowserReport } from "./browser-report";

const appOrigin = "https://svp.localhost:8443";
const chunk = `${appOrigin}/_next/static/chunks/0khh50nt3ldfz.js`;
const debugId = "8f1c2a4e-5b6d-4e7f-9a0b-1c2d3e4f5a6b";

function report(overrides: Partial<BrowserReport> = {}): BrowserReport {
  return {
    name: "TypeError",
    message: "Cannot read properties of undefined (reading 'video_id')",
    stack: [
      "TypeError: Cannot read properties of undefined (reading 'video_id')",
      `    at FeedItem (${chunk}?dpl=dev-1:1:2345)`,
      `    at ${appOrigin}/_next/static/chunks/1jhg85q6z02q4.js:2:10`,
    ].join("\n"),
    path: "/v/0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d",
    debug_ids: { [chunk]: debugId },
    ...overrides,
  };
}

describe("parseStack", () => {
  it("reads Chromium's stack, oldest frame first, without the query", () => {
    expect(parseStack(report().stack)).toEqual([
      {
        function: "?",
        filename: `${appOrigin}/_next/static/chunks/1jhg85q6z02q4.js`,
        abs_path: `${appOrigin}/_next/static/chunks/1jhg85q6z02q4.js`,
        lineno: 2,
        colno: 10,
      },
      { function: "FeedItem", filename: chunk, abs_path: chunk, lineno: 1, colno: 2345 },
    ]);
  });

  it("reads WebKit's and Firefox's stacks", () => {
    const stack = [`play@${chunk}:1:20`, `@${chunk}:1:5`, "global code@https://svp.localhost:8443/v/x:3:4"].join("\n");
    expect(parseStack(stack).map(({ function: name, lineno, colno }) => [name, lineno, colno])).toEqual([
      ["global code", 3, 4],
      ["?", 1, 5],
      ["play", 1, 20],
    ]);
  });

  it("skips lines that are not frames and keeps the newest 50", () => {
    const lines = ["Error: boom", "    at async Promise.all (index 0)", "[native code]"];
    for (let i = 1; i <= 60; i++) {
      lines.push(`    at f${i} (${chunk}:1:${i})`);
    }
    const frames = parseStack(lines.join("\n"));
    expect(frames).toHaveLength(50);
    expect(frames.at(-1)?.function).toBe("f1");
    expect(frames[0]?.function).toBe("f50");
  });

  it("keeps a line of 1 KiB and skips a longer one before matching it", () => {
    const frame = (length: number) => {
      const line = `    at f (${appOrigin}/_next/static/chunks/.js:1:2)`;
      return line.replace("/.js", `/${"a".repeat(length - line.length)}.js`);
    };
    // The worst case of the WebKit pattern: every "@" may end the function name and every ":1" start the position.
    const worst = "@".repeat(8001) + ":1".repeat(3999) + "x";
    expect(worst).toHaveLength(16_000);
    // Every match of a regular expression goes through exec once it is replaced.
    const exec = vi.spyOn(RegExp.prototype, "exec");
    const frames = parseStack([frame(1024), worst, frame(1025), `play@${chunk}:1:20`].join("\n"));
    const longest = Math.max(...exec.mock.calls.map(([input]) => String(input).length));
    exec.mockRestore();
    expect(frames.map(({ function: name, abs_path }) => [name, abs_path?.length])).toEqual([
      ["play", chunk.length],
      ["f", 1024 - "    at f (:1:2)".length],
    ]);
    expect(longest).toBe(1024);
  });
});

describe("routeTemplate", () => {
  it.each([
    ["/", "/"],
    ["/following", "/following"],
    ["/login", "/login"],
    ["/register", "/register"],
    ["/me", "/me"],
    ["/upload", "/upload"],
    ["/u/minhanh", "/u/[handle]"],
    ["/v/0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d", "/v/[id]"],
    ["/v/a/b", "other"],
    ["/admin", "other"],
  ])("maps %s to %s", (path, template) => {
    expect(routeTemplate(path)).toBe(template);
  });
});

describe("browserReportSchema", () => {
  it("accepts a report", () => {
    expect(browserReportSchema.safeParse(report()).success).toBe(true);
  });

  it.each<[string, unknown]>([
    ["a missing field", { ...report(), stack: undefined }],
    ["a long name", report({ name: "x".repeat(201) })],
    ["a long message", report({ message: "x".repeat(1_001) })],
    ["a long stack", report({ stack: "x".repeat(16_001) })],
    ["a long path", report({ path: `/${"x".repeat(500)}` })],
    ["a path that is not a path", report({ path: "https://evil.example/" })],
    ["a debug id that is not a UUID", report({ debug_ids: { [chunk]: "abc" } })],
    [
      "more than 64 debug ids",
      report({ debug_ids: Object.fromEntries(Array.from({ length: 65 }, (_, i) => [`${chunk}${i}`, debugId])) }),
    ],
    ["not an object", "TypeError"],
  ])("refuses %s", (_case, value) => {
    expect(browserReportSchema.safeParse(value).success).toBe(false);
  });
});

describe("browserEvent", () => {
  it("builds the event from the report's fields alone", () => {
    const event = browserEvent(
      browserReportSchema.parse({ ...report(), path: "/v/0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d?t=1#x", cookie: "a" }),
      { appOrigin },
    );
    expect(event).toEqual({
      type: undefined,
      platform: "javascript",
      level: "error",
      exception: {
        values: [
          {
            type: "TypeError",
            value: "Cannot read properties of undefined (reading 'video_id')",
            stacktrace: { frames: expect.any(Array) },
            mechanism: { type: "onerror", handled: false },
          },
        ],
      },
      request: { url: `${appOrigin}/v/0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d` },
      tags: { service: "web", runtime: "browser", route: "/v/[id]" },
      debug_meta: { images: [{ type: "sourcemap", code_file: chunk, debug_id: debugId }] },
    });
    expect(event.exception?.values?.[0]?.stacktrace?.frames?.every((frame) => frame.in_app)).toBe(true);
  });

  it("maps no chunk outside the app's static files, and no frame without a debug id", () => {
    const foreign = "https://cdn.example/_next/static/chunks/a.js";
    const event = browserEvent(
      report({
        stack: [`    at f (${foreign}:1:1)`, `    at g (${chunk}:1:1)`].join("\n"),
        debug_ids: { [foreign]: debugId },
      }),
      { appOrigin },
    );
    expect(event.debug_meta).toBeUndefined();
    expect(event.exception?.values?.[0]?.stacktrace?.frames?.map((frame) => frame.in_app)).toEqual([true, false]);
  });

  it("keeps the request to the app's origin whatever the path says", () => {
    expect(browserEvent(report({ path: "//evil.example/x" }), { appOrigin }).request).toEqual({
      url: `${appOrigin}/x`,
    });
  });

  it("names an error without a name Error and leaves out an empty stack", () => {
    const value = browserEvent(report({ name: "", stack: "" }), { appOrigin }).exception?.values?.[0];
    expect(value?.type).toBe("Error");
    expect(value).not.toHaveProperty("stacktrace");
  });
});
