// Liveness of the web server for container and cluster probes: answers from the process alone, without reading the
// session or calling the gateway, so a gateway outage does not get healthy web pods restarted.
export const dynamic = "force-dynamic";

export function GET(): Response {
  return Response.json({ status: "ok" }, { headers: { "Cache-Control": "no-store" } });
}
