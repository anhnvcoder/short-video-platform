import "server-only";

// CSRF check for every request that may change state: every method but GET and HEAD, Server Actions, Route Handlers
// and /api/* alike. No route changes state on GET.
//
// Sec-Fetch-Site must be exactly same-origin, not same-site: s3.svp.localhost serves files users uploaded and is the
// same site as svp.localhost, and a SameSite=Lax cookie still goes along with a request from a sibling host. Browsers
// without Fetch Metadata send Origin, which must then be the app's origin exactly; `Origin: null` (sandboxed frames,
// some redirects) never matches. A request with neither header is refused.
export function isSafeMethod(method: string): boolean {
  return method === "GET" || method === "HEAD";
}

export function passesCsrfCheck(method: string, headers: Headers, appOrigin: string): boolean {
  if (isSafeMethod(method)) {
    return true;
  }
  const fetchSite = headers.get("sec-fetch-site");
  if (fetchSite !== null) {
    return fetchSite === "same-origin";
  }
  return headers.get("origin") === appOrigin;
}
