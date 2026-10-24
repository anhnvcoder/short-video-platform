import exec from "k6/execution";
import http from "k6/http";
import { parseHTML } from "k6/html";
import { profile, targets } from "./config.js";
import { send } from "./http.js";

// setup(): the user pool and the videos the load uses. Every user is new to this run, with a random password that
// exists only in this process's memory; tokens and session cookies go to the VUs in setup's return value, which
// handleSummary never writes (lib/summary.js). Nothing here is logged but counts.

const setupRoutes = {
  register: { route: "/auth/register", app: "api", status: 201 },
  login: { route: "/auth/login", app: "api", status: 200 },
  explore: { route: "/feed/explore", app: "api", status: 200 },
  loginPage: { route: "/login", app: "web", status: 200 },
  loginForm: { route: "/login", app: "web", status: 303 },
};

function randomHex(bytes) {
  const b = new Uint8Array(bytes);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

function json(res, what) {
  try {
    return res.json();
  } catch (e) {
    throw new Error(`${what}: the response is not JSON`);
  }
}

// The web client sees the browser's origin, not the address k6 dials (compose: http://web:3001 with Host and Origin of
// http://localhost:3001). Next compares the host of Origin with Host for a Server Action, and the web's CSRF check
// compares Origin with APP_ORIGIN, so both headers carry the origin users open.
export function webHeaders(t) {
  return { Host: t.webOrigin.replace(/^https?:\/\//, "") };
}

// multipart/form-data body of FIELDS (name -> string), built here: Next 16 runs a form-posted Server Action only from
// a multipart body (an urlencoded one renders the page again), and k6 builds multipart only around a file.
function multipart(fields) {
  const boundary = `svpk6${randomHex(12)}`;
  let body = "";
  for (const [name, value] of Object.entries(fields)) {
    body += `--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`;
  }
  body += `--${boundary}--\r\n`;
  return { body, contentType: `multipart/form-data; boundary=${boundary}` };
}

// webLogin: logs USER in through the web's login form as a browser without JavaScript does: GET /login, every hidden
// field of the form (the Server Action's ids and state, `next` when present), email and password, posted back with the
// app's Origin. The 303 answer sets the session cookie; its name and value go back to the caller only.
function webLogin(t, user) {
  const phase = "setup";
  const page = send("GET", `${t.webURL}/login`, null, setupRoutes.loginPage, {
    phase,
    headers: webHeaders(t),
    responseType: "text",
  });
  if (page.status !== 200) {
    throw new Error(`GET /login of the web answered ${page.status}`);
  }
  const forms = parseHTML(page.body)
    .find("form")
    .toArray()
    .filter((f) => f.find('input[name="email"]').size() > 0);
  if (forms.length !== 1) {
    throw new Error(`GET /login of the web has ${forms.length} forms with an email field, not 1`);
  }
  const form = forms[0];
  const fields = {};
  form.find('input[type="hidden"]').each((_, el) => {
    const name = el.attributes().name;
    if (name) {
      fields[name.value] = el.attributes().value ? el.attributes().value.value : "";
    }
  });
  if (!Object.keys(fields).some((name) => name.startsWith("$ACTION"))) {
    throw new Error("the login form of the web has no Server Action fields");
  }
  fields.email = user.email;
  fields.password = user.password;
  const { body, contentType } = multipart(fields);
  const res = send("POST", `${t.webURL}/login`, body, setupRoutes.loginForm, {
    phase,
    headers: { ...webHeaders(t), Origin: t.webOrigin, "Content-Type": contentType },
    jar: new http.CookieJar(),
  });
  const cookies = {};
  for (const [name, list] of Object.entries(res.cookies)) {
    if (list.length > 0 && list[0].value !== "") {
      cookies[name] = list[0].value;
    }
  }
  if (res.status !== 303 || Object.keys(cookies).length === 0) {
    throw new Error(`the login form of the web answered ${res.status} with ${Object.keys(cookies).length} cookies`);
  }
  return cookies;
}

// The ids of up to 50 READY videos, newest first: GET /feed/explore holds READY videos only.
function readyVideos(t, token) {
  const res = send("GET", `${t.apiURL}/feed/explore?page_size=50`, null, setupRoutes.explore, {
    phase: "setup",
    headers: { Authorization: `Bearer ${token}` },
    responseType: "text",
  });
  if (res.status !== 200) {
    throw new Error(`GET /feed/explore answered ${res.status}`);
  }
  return (json(res, "GET /feed/explore").items || []).map((item) => item.video_id).filter(Boolean);
}

// The profile's VUs and per-user rates assume `pods` processes, each running one of as many execution segments (the
// cloud Job: --execution-segment-sequence of 20; local and ci: none). Read here because the options are not known in
// the init context.
function checkSegments() {
  const sequence = exec.test.options.executionSegmentSequence;
  const segments = sequence ? sequence.split(",").length - 1 : 1;
  if (segments !== profile.pods) {
    throw new Error(`profile ${profile.name} is sized for ${profile.pods} execution segments, not ${segments}`);
  }
}

export function createPool() {
  checkSegments();
  const t = targets();
  const run = randomHex(4);
  const users = [];
  for (let i = 0; i < profile.users; i++) {
    const user = { email: `k6-${run}-${i}@example.test`, password: randomHex(16) };
    const credentials = JSON.stringify(user);
    const jsonHeaders = { "Content-Type": "application/json" };
    const reg = send("POST", `${t.apiURL}/auth/register`, credentials, setupRoutes.register, {
      phase: "setup",
      headers: jsonHeaders,
    });
    if (reg.status !== 201) {
      throw new Error(`POST /auth/register of user ${i} answered ${reg.status}; is the register rate limit reset?`);
    }
    const login = send("POST", `${t.apiURL}/auth/login`, credentials, setupRoutes.login, {
      phase: "setup",
      headers: jsonHeaders,
      responseType: "text",
    });
    if (login.status !== 200) {
      throw new Error(`POST /auth/login of user ${i} answered ${login.status}`);
    }
    users.push({ ...user, token: json(login, "POST /auth/login").access_token });
  }
  const videos = readyVideos(t, users[0].token);
  if (videos.length === 0) {
    throw new Error("no READY video in GET /feed/explore: publish one first (make smoke), the script never measures /v/[id] with a made-up id");
  }
  const sessions = [];
  for (let i = 0; i < profile.webSessions; i++) {
    sessions.push(webLogin(t, users[i]));
  }
  console.log(
    `setup: ${users.length} users, ${sessions.length} web sessions, ${videos.length} READY videos (profile ${profile.name}, hold ${profile.hold})`,
  );
  // Passwords stay here: the VUs need tokens and cookies only.
  return { targets: t, tokens: users.map((u) => u.token), sessions, videos };
}
