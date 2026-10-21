import type { NextRequest } from "next/server";
import { proxyApiRequest } from "@/server/api-proxy";
import { problem } from "@/server/problem";
import { bffServices } from "@/server/runtime";

// Every method goes through one handler, so a path outside the allowed routes is a 404 whatever the method, and a
// known path with the wrong method a 405 (server/api-proxy.ts).
async function handle(request: NextRequest): Promise<Response> {
  let services;
  try {
    services = await bffServices();
  } catch {
    return problem(503, "UNAVAILABLE");
  }
  return proxyApiRequest(request, services);
}

export const GET = handle;
export const HEAD = handle;
export const POST = handle;
export const PUT = handle;
export const PATCH = handle;
export const DELETE = handle;
export const OPTIONS = handle;
