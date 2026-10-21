import { STATUS_CODES } from "node:http";

// An RFC 9457 problem in the shape the gateway answers with (docs/architecture.md §8.4), for errors the web server
// raises itself. Never cached.
export function problem(status: number, code: string, headers: Record<string, string> = {}): Response {
  return Response.json(
    { type: "about:blank", title: STATUS_CODES[status] ?? "Error", status, detail: "", code },
    {
      status,
      headers: { "Content-Type": "application/problem+json", "Cache-Control": "no-store", ...headers },
    },
  );
}
