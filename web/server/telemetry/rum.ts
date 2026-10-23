import "server-only";
import { z } from "zod";
import { problem } from "../problem";
import type { WindowBudget } from "../sentry/limiter";
import { isVideoId } from "../video-page";
import { vitalNames, vitals, type RouteTemplate, type VitalsRecorder } from "./vitals";

// POST /rum: the web vitals of one page load, sent by the browser as a beacon
// (docs/adr/0019-web-k3d-supply-chain-observability.md, section 11). proxy.ts has already checked it comes from the
// app's own pages (CSRF). Anyone who can open a page can still send numbers here, so what a beacon can do is bounded:
// a closed set of label values (no new series), a ceiling on each value, a small body and a rate per process. Nothing
// about the sender is kept: no user id, session, full URL or User-Agent, and nothing is logged.

export const maxBeaconBytes = 4 * 1024;

const beaconSchema = z.object({
  // The page's pathname when it loaded.
  path: z.string().max(500),
  metrics: z
    .array(z.object({ name: z.enum(vitalNames), value: z.number() }))
    .min(1)
    .max(5)
    .refine((metrics) => new Set(metrics.map((metric) => metric.name)).size === metrics.length, "a metric repeats"),
});

export interface RumDeps {
  // Beacons of this process: 600 a minute, whoever sends them (all clients may share one or two addresses).
  budget: WindowBudget;
  recorder(): VitalsRecorder;
}

const staticRoutes = new Set<RouteTemplate>(["/", "/following", "/login", "/register", "/me", "/upload"]);
const handlePattern = /^[a-z][a-z0-9_]{2,29}$/;

// The route template of a page's path, or null when it is none of the app's pages: such a beacon is dropped whole,
// there is no "other" label.
export function routeOf(path: string): RouteTemplate | null {
  if (staticRoutes.has(path as RouteTemplate)) {
    return path as RouteTemplate;
  }
  const [, section, value, ...rest] = path.split("/");
  if (rest.length > 0 || value === undefined) {
    return null;
  }
  if (section === "u" && handlePattern.test(value)) {
    return "/u/[handle]";
  }
  if (section === "v" && isVideoId(value)) {
    return "/v/[id]";
  }
  return null;
}

// The body as text, or null when it is larger than the limit.
async function readText(request: Request): Promise<string | null> {
  if (Number(request.headers.get("content-length") ?? 0) > maxBeaconBytes) {
    return null;
  }
  if (request.body === null) {
    return "";
  }
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    size += value.byteLength;
    if (size > maxBeaconBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

export async function handleRumBeacon(request: Request, { budget, recorder }: RumDeps): Promise<Response> {
  const text = await readText(request);
  if (text === null) {
    return problem(413, "PAYLOAD_TOO_LARGE");
  }
  // The body is JSON sent as text/plain, the type sendBeacon gives a string; the media type is not checked.
  const beacon = beaconSchema.safeParse(parseJson(text));
  if (!beacon.success) {
    return problem(400, "INVALID_BEACON");
  }
  if (!budget.take()) {
    return problem(429, "RATE_LIMITED", { "Retry-After": "60" });
  }
  const route = routeOf(beacon.data.path);
  if (route !== null) {
    for (const { name, value } of beacon.data.metrics) {
      // Negative or above the ceiling cannot be a real measurement; that one value is dropped.
      if (value >= 0 && value <= vitals[name].max) {
        recorder().record(name, value, route);
      }
    }
  }
  // 204 for a dropped beacon too: the browser does not read the answer, and a sender learns nothing from it.
  return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}
