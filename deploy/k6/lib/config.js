// Profiles, scenarios and thresholds of the load test (docs/adr/0020-reliability-stage6.md, section 2). One profile is
// picked with SVP_K6_PROFILE; every rate below is per minute, so a route of less than one request a second (POST
// /videos) needs no fractional rate. Cloud rates are the totals of the whole Job: k6 splits them across the `pods`
// processes by --execution-segment, while each pod registers its own pool in setup() (one pool per source address).

const holdPattern = /^[1-9][0-9]*[smh]$/;

// Each route of the scenarios: the tag `route` (the gateway's OpenAPI path or the Next route, the same text as the
// server's http_route and the RUM route label, so k6 and server numbers pair up), its app and the status it expects.
export const routes = {
  explore: { route: "/feed/explore", app: "api", status: 200 },
  following: { route: "/feed/following", app: "api", status: 200 },
  like: { route: "/videos/{video_id}/like", app: "api", status: 204 },
  view: { route: "/videos/{video_id}/views", app: "api", status: 202 },
  upload: { route: "/videos", app: "api", status: 201 },
  home: { route: "/", app: "web", status: 200 },
  video: { route: "/v/[id]", app: "web", status: 200 },
  login: { route: "/login", app: "web", status: 200 },
};

// Pool sizes keep every per-user and per-address limit of the gateway out of reach (the route, class, key and limit
// table of ADR-0020, section 2): `users` register and log in once at the gateway (register burst 20 per address, login
// burst 30), `webSessions` of them log in once more through the web form; a user's read rate stays under 10/s and its
// POST /videos under the 3 open uploads per 15 minutes of video-service. `pods` is how many k6 processes share the
// rates, each with its own pool: the per-user numbers hold only when every one of them runs its share (setup() checks
// the execution segments against it).
const profiles = {
  // make load-local: one container, one address; the target resets the register buckets first (LOCAL LAB ONLY).
  local: {
    executor: "ramping-arrival-rate",
    ramp: "30s",
    hold: "5m",
    rampDown: null,
    pods: 1,
    users: 20,
    webSessions: 5,
    perMinute: { explore: 540, following: 420, like: 60, view: 120, upload: 3, home: 180, video: 60, login: 60 },
    latencyThresholds: true,
  },
  // make load-ci: a shared runner, so error thresholds only, no latency.
  ci: {
    executor: "constant-arrival-rate",
    hold: "60s",
    pods: 1,
    users: 5,
    webSessions: 2,
    perMinute: { explore: 60, following: 60, like: 30, view: 30, upload: 2, home: 60, video: 30, login: 30 },
    latencyThresholds: false,
  },
  // The Job of deploy/k6/cloud/ (stage 7): 20 pods (completions of job.yaml.in), 12 users and 2 web sessions each;
  // 1 000 feed requests a second.
  cloud: {
    executor: "ramping-arrival-rate",
    ramp: "10m",
    hold: "10m",
    rampDown: "1m",
    pods: 20,
    users: 12,
    webSessions: 2,
    perMinute: {
      explore: 33000,
      following: 27000,
      like: 3000,
      view: 6000,
      upload: 30,
      home: 3600,
      video: 1800,
      login: 600,
    },
    latencyThresholds: true,
  },
};

function env(name) {
  return (__ENV[name] || "").trim();
}

const profileName = env("SVP_K6_PROFILE");
if (!Object.prototype.hasOwnProperty.call(profiles, profileName)) {
  throw new Error(`SVP_K6_PROFILE must be one of ${Object.keys(profiles).join(", ")} (got "${profileName}")`);
}
const hold = env("SVP_K6_HOLD") || profiles[profileName].hold;
if (!holdPattern.test(hold)) {
  throw new Error(`SVP_K6_HOLD must be a whole number of s, m or h, like 5m (got "${hold}")`);
}
const forwardedFor = env("SVP_K6_FORWARDED_FOR");
if (forwardedFor !== "" && !/^[0-9a-f.:]+$/i.test(forwardedFor)) {
  throw new Error(`SVP_K6_FORWARDED_FOR must be an IP address (got "${forwardedFor}")`);
}

export const profile = { name: profileName, ...profiles[profileName], hold };

// Targets, read in setup() rather than here so that `k6 inspect` (make k6-check) needs none of them.
export function targets() {
  const t = {
    apiURL: env("SVP_API_URL").replace(/\/+$/, ""),
    webURL: env("SVP_WEB_URL").replace(/\/+$/, ""),
    webOrigin: env("SVP_WEB_ORIGIN").replace(/\/+$/, ""),
  };
  for (const [name, value] of Object.entries({
    SVP_API_URL: t.apiURL,
    SVP_WEB_URL: t.webURL,
    SVP_WEB_ORIGIN: t.webOrigin,
  })) {
    if (!/^https?:\/\/[^/\s]+$/.test(value)) {
      throw new Error(`${name} must be an http(s) origin with no path, like http://gateway:8080 (got "${value}")`);
    }
  }
  return t;
}

// The address each request claims in X-Forwarded-For, or "" for none. Set only in the cloud Job when stage 7 trusts two
// hops (a load balancer before Envoy): the Job then calls Envoy directly and plays the load balancer's part, writing
// its own pod IP and no other (threat model RL-7).
export const forwardedForIP = forwardedFor;

// Iterations an arrival-rate executor may run at once, sized per pod and multiplied by `pods`: about 300 ms of work per
// request in flight before it starts more VUs, and room for latency to grow to 2 s before it drops iterations
// (dropped_iterations then says so). k6 splits VUs across the execution segments as it splits the rate, and gives a
// scenario's iterations only to the segments that get at least one of its maxVUs: sized on the Job's total, a slow
// route (POST /videos, 3 VUs at most) would run on 3 of the 20 pods with their 36 users instead of all 240, and a pod
// left with no pre-allocated VU drops its first iteration while it starts one.
function vus(perMinute) {
  const perSecond = perMinute / profile.pods / 60;
  return {
    preAllocatedVUs: profile.pods * (Math.ceil(perSecond * 0.3) + 1),
    maxVUs: profile.pods * (Math.ceil(perSecond * 2) + 2),
  };
}

export function scenarios(execNames) {
  const out = {};
  for (const [key, perMinute] of Object.entries(profile.perMinute)) {
    const base = {
      exec: execNames[key],
      timeUnit: "1m",
      ...vus(perMinute),
      tags: { phase: "load", app: routes[key].app },
    };
    if (profile.executor === "constant-arrival-rate") {
      out[key] = { ...base, executor: "constant-arrival-rate", rate: perMinute, duration: profile.hold };
    } else {
      const stages = [
        { duration: profile.ramp, target: perMinute },
        { duration: profile.hold, target: perMinute },
      ];
      if (profile.rampDown) {
        stages.push({ duration: profile.rampDown, target: 0 });
      }
      out[key] = { ...base, executor: "ramping-arrival-rate", startRate: 0, stages };
    }
  }
  return out;
}

// The SLO -> threshold table of ADR-0020, section 2. Every route also gets threshold-less sub-metrics ([]) so that the
// summary reports its count, failures, p95 and p99 on their own.
export function thresholds() {
  const t = {};
  for (const { route } of Object.values(routes)) {
    t[`http_reqs{route:${route},phase:load}`] = [];
    t[`http_req_duration{route:${route},phase:load}`] = [];
    t[`http_req_failed{route:${route},phase:load}`] = [];
    t[`svp_rate_limited{route:${route}}`] = [];
  }
  // feed-availability, upload-init-availability, and the like and view routes, which have no SLO but no excuse for 5xx.
  for (const key of ["explore", "following", "upload", "like", "view"]) {
    t[`http_req_failed{route:${routes[key].route},phase:load}`] = ["rate<0.001"];
  }
  // web-availability over every page of the web client.
  t["http_req_failed{app:web,phase:load}"] = ["rate<0.001"];
  if (profile.latencyThresholds) {
    // feed-latency: 99% within 150 ms. Web SSR latency has no SLO (ADR-0020, section 3), its p95/p99 are only reported.
    for (const key of ["explore", "following"]) {
      t[`http_req_duration{route:${routes[key].route},phase:load}`] = ["p(99)<150"];
    }
    t.dropped_iterations = ["count==0"];
  }
  // A script sized right never meets a rate limit, and every response has the status it expects.
  t.svp_rate_limited = ["count==0"];
  t["checks{phase:load}"] = ["rate>0.999"];
  return t;
}
