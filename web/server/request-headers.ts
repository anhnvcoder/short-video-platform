// Request header carrying the path and query of the page, for server code that sends a logged-out user to
// /login?next=<path>. proxy.ts sets it on every request, so a value sent by the browser never reaches the renderer.
export const pathHeader = "x-svp-path";
