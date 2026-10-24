import { check } from "k6";
import http from "k6/http";
import { Counter } from "k6/metrics";
import { forwardedForIP } from "./config.js";

// 4xx answers are the client's, so http_req_failed counts only 5xx and connection errors, as the SLOs count 5xx. A 429
// is counted on its own instead: the script hitting a rate limit means its user pool is too small, not that the system
// failed (ADR-0020, section 2).
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

export const rateLimited = new Counter("svp_rate_limited");

// A request must not hang an iteration: past 10 s it counts as a failure and the VU moves on.
const timeout = "10s";

// send METHOD URL BODY SPEC PARAMS: one request tagged with its route template, as both `route` and `name` (the name k6
// groups URLs by, so /v/<id> stays one entry), with a check of the status SPEC expects. PARAMS adds headers, cookies, a
// jar, `phase` for setup requests and responseType "text" when the body is read (bodies are discarded otherwise).
export function send(method, url, body, spec, params = {}) {
  const tags = { route: spec.route, name: spec.route, app: spec.app };
  if (params.phase) {
    tags.phase = params.phase;
  }
  const headers = { ...(params.headers || {}) };
  if (forwardedForIP) {
    headers["X-Forwarded-For"] = forwardedForIP;
  }
  const options = { headers, tags, timeout, redirects: 0, responseType: params.responseType || "none" };
  if (params.cookies) {
    options.cookies = params.cookies;
  }
  if (params.jar) {
    options.jar = params.jar;
  }
  const res = http.request(method, url, body, options);
  if (res.status === 429) {
    rateLimited.add(1, { route: spec.route });
  }
  const checkTags = { route: spec.route };
  if (params.phase) {
    checkTags.phase = params.phase;
  }
  check(res, { [`${method} ${spec.route} is ${spec.status}`]: (r) => r.status === spec.status }, checkTags);
  return res;
}
