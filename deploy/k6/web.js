import exec from "k6/execution";
import http from "k6/http";
import { routes } from "./lib/config.js";
import { send } from "./lib/http.js";
import { webHeaders } from "./lib/setup.js";

// Scenarios of the web client's server-side rendering: the explore feed logged in, the public
// share page as a guest, and the login page. Redirects are not followed, so a lost session shows as a failed check
// (a redirect to /login) rather than as the login page's 200.

function pick(list) {
  return list[exec.scenario.iterationInInstance % list.length];
}

// SSR of the explore feed: the web calls GET /feed/explore at the gateway with the session's token. A fresh jar each
// time, so a cookie another session's page set never replaces this session's.
export function home(data) {
  send("GET", `${data.targets.webURL}/`, null, routes.home, {
    headers: webHeaders(data.targets),
    cookies: pick(data.sessions),
    jar: new http.CookieJar(),
  });
}

// A guest, with a jar of its own each time so that no cookie a page set reaches it. The web calls GET
// /public/videos/{id}, rate limited by the address the gateway sees.
export function sharePage(data) {
  send("GET", `${data.targets.webURL}/v/${pick(data.videos)}`, null, routes.video, {
    headers: webHeaders(data.targets),
    jar: new http.CookieJar(),
  });
}

// No session, so the web renders the form without calling the gateway.
export function loginPage(data) {
  send("GET", `${data.targets.webURL}/login`, null, routes.login, {
    headers: webHeaders(data.targets),
    jar: new http.CookieJar(),
  });
}
