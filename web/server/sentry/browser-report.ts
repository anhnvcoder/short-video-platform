import "server-only";
import type { ErrorEvent, StackFrame } from "@sentry/nextjs";
import { z } from "zod";
import { withoutQuery } from "./scrub";

// A browser's error report to POST /monitoring. The
// browser carries no Sentry SDK and no DSN: it sends this small closed shape, and the server builds the event from it.

const debugIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const browserReportSchema = z.object({
  name: z.string().max(200),
  message: z.string().max(1_000),
  stack: z.string().max(16_000),
  path: z.string().max(500).startsWith("/"),
  // Debug id of each chunk in the stack, by the chunk's URL: what maps a frame to its source map.
  debug_ids: z
    .record(z.string().max(2_000), z.string().regex(debugIdPattern))
    .refine((ids) => Object.keys(ids).length <= 64, "at most 64 entries"),
});

export type BrowserReport = z.infer<typeof browserReportSchema>;

// Route templates of the app (the label set of the web-vitals metrics too); any other path is `other`, so a tag never
// carries a handle or an id.
const routeTemplates: [RegExp, string][] = [
  [/^\/$/, "/"],
  [/^\/following$/, "/following"],
  [/^\/login$/, "/login"],
  [/^\/register$/, "/register"],
  [/^\/me$/, "/me"],
  [/^\/upload$/, "/upload"],
  [/^\/u\/[^/]+$/, "/u/[handle]"],
  [/^\/v\/[^/]+$/, "/v/[id]"],
];

export function routeTemplate(pathname: string): string {
  return routeTemplates.find(([pattern]) => pattern.test(pathname))?.[1] ?? "other";
}

// One line of an Error's stack. Chromium: `    at fn (url:1:2)`, `    at url:1:2`. WebKit and Firefox: `fn@url:1:2`,
// `@url:1:2`, `url:1:2`.
const chromiumFrame = /^\s*at (?:(.+?) \()?(.+?):(\d+):(\d+)\)?$/;
const otherFrame = /^\s*(?:(.*?)@)?(.+?):(\d+):(\d+)$/;

// Frames kept from one stack: the newest ones, as the SDKs do.
const maxFrames = 50;
// A longer line is skipped before the patterns above read it: a frame is a function name and a URL with its position,
// far shorter. Their lazy groups backtrack, so their cost grows with the square of a line's length, and the stack
// comes from an unauthenticated report (a 16 KB line took a third of a second of the event loop).
const maxFrameLength = 1024;

export function parseStack(stack: string): StackFrame[] {
  const frames: StackFrame[] = [];
  for (const line of stack.split("\n")) {
    if (line.length > maxFrameLength) {
      continue;
    }
    const match = chromiumFrame.exec(line) ?? (line.includes(" at ") ? null : otherFrame.exec(line));
    if (!match) {
      continue;
    }
    const [, name, location = "", lineno, colno] = match;
    const url = withoutQuery(location) ?? location;
    frames.push({
      function: name || "?",
      filename: url,
      abs_path: url,
      lineno: Number(lineno),
      colno: Number(colno),
    });
    if (frames.length === maxFrames) {
      break;
    }
  }
  // A stack lists the newest call first; Sentry wants the oldest first.
  return frames.reverse();
}

export interface BrowserEventOptions {
  appOrigin: string;
}

// The event for one report. Nothing of the report goes in but these fields; the scrubbing rules run on it later, in
// the SDK's beforeSend, as on every event.
export function browserEvent(report: BrowserReport, { appOrigin }: BrowserEventOptions): ErrorEvent {
  const pathname = new URL(report.path, appOrigin).pathname;
  const staticPrefix = `${appOrigin}/_next/static/`;
  const frames = parseStack(report.stack).map((frame) => ({
    ...frame,
    in_app: frame.abs_path?.startsWith(staticPrefix) ?? false,
  }));

  const debugIds = new Map<string, string>();
  for (const [url, id] of Object.entries(report.debug_ids)) {
    const chunk = withoutQuery(url);
    if (chunk?.startsWith(staticPrefix)) {
      debugIds.set(chunk, id.toLowerCase());
    }
  }
  const images = [...new Set(frames.map((frame) => frame.abs_path))].flatMap((url) => {
    const debugId = url === undefined ? undefined : debugIds.get(url);
    return url === undefined || debugId === undefined
      ? []
      : [{ type: "sourcemap" as const, code_file: url, debug_id: debugId }];
  });

  return {
    type: undefined,
    platform: "javascript",
    level: "error",
    exception: {
      values: [
        {
          type: report.name || "Error",
          value: report.message,
          ...(frames.length > 0 && { stacktrace: { frames } }),
          mechanism: { type: "onerror", handled: false },
        },
      ],
    },
    request: { url: appOrigin + pathname },
    tags: { service: "web", runtime: "browser", route: routeTemplate(pathname) },
    ...(images.length > 0 && { debug_meta: { images } }),
  };
}
