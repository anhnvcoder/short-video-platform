import { profile, routes, targets, forwardedForIP } from "./config.js";

// handleSummary: a chosen subset of the end-of-test data, never the whole of it. The object k6 passes in also holds
// setup_data, the pool's tokens and session cookies, so it is never written as is; nor are
// --summary-export or --out json used. With SVP_K6_RESULTS set (make load-local, make load-ci) the JSON goes to
// <SVP_K6_RESULTS>/summary.json; without it (the cloud Job) to one stdout line starting with "svp-k6-summary ", which
// the learner gathers from the pods' logs. A short table goes to stdout either way.

// Metrics kept in the JSON, with their per-route and per-phase sub-metrics.
const kept = /^(http_reqs|http_req_duration|http_req_failed|svp_rate_limited|checks|dropped_iterations|iterations|vus_max)(\{|$)/;

function round(x) {
  return typeof x === "number" ? Math.round(x * 100) / 100 : null;
}

function routeRows(metrics) {
  return Object.values(routes).map(({ route, app }) => {
    const reqs = metrics[`http_reqs{route:${route},phase:load}`];
    const dur = metrics[`http_req_duration{route:${route},phase:load}`];
    const failed = metrics[`http_req_failed{route:${route},phase:load}`];
    const limited = metrics[`svp_rate_limited{route:${route}}`];
    return {
      route,
      app,
      requests: reqs ? reqs.values.count : 0,
      per_second: reqs ? round(reqs.values.rate) : 0,
      failed_rate: failed ? failed.values.rate : null,
      med_ms: dur ? round(dur.values.med) : null,
      p95_ms: dur ? round(dur.values["p(95)"]) : null,
      p99_ms: dur ? round(dur.values["p(99)"]) : null,
      max_ms: dur ? round(dur.values.max) : null,
      rate_limited: limited ? limited.values.count : 0,
    };
  });
}

function thresholdRows(metrics) {
  const rows = [];
  for (const [metric, m] of Object.entries(metrics)) {
    for (const [expression, result] of Object.entries(m.thresholds || {})) {
      rows.push({ metric, expression, ok: result.ok });
    }
  }
  return rows;
}

function checkRows(group) {
  const rows = (group.checks || []).map((c) => ({ name: c.name, passes: c.passes, fails: c.fails }));
  for (const g of group.groups || []) {
    rows.push(...checkRows(g));
  }
  return rows;
}

function conditions() {
  let t;
  try {
    t = targets();
  } catch (e) {
    t = {};
  }
  return {
    executor: profile.executor,
    ramp: profile.ramp || null,
    hold: profile.hold,
    ramp_down: profile.rampDown || null,
    users: profile.users,
    web_sessions: profile.webSessions,
    per_minute: profile.perMinute,
    api_url: t.apiURL || null,
    web_url: t.webURL || null,
    web_origin: t.webOrigin || null,
    forwarded_for: forwardedForIP !== "",
  };
}

function text(s) {
  const pad = (v, n) => String(v === null ? "-" : v).padStart(n);
  const lines = [
    `k6 profile ${s.profile}: ${s.thresholds_ok ? "every threshold passed" : "THRESHOLDS FAILED"}`,
    `${"route".padEnd(26)}${pad("reqs", 8)}${pad("req/s", 8)}${pad("5xx%", 8)}${pad("p95 ms", 9)}${pad("p99 ms", 9)}${pad("429", 6)}`,
  ];
  for (const r of s.routes) {
    const failed = r.failed_rate === null ? null : round(r.failed_rate * 100);
    lines.push(
      `${r.route.padEnd(26)}${pad(r.requests, 8)}${pad(r.per_second, 8)}${pad(failed, 8)}${pad(r.p95_ms, 9)}${pad(r.p99_ms, 9)}${pad(r.rate_limited, 6)}`,
    );
  }
  lines.push(`dropped_iterations ${s.dropped_iterations}, checks ${s.checks.passes} passed / ${s.checks.fails} failed`);
  if (s.load_requests === 0) {
    lines.push("FAIL  no request of the load phase: the run stopped before it (in setup?)");
  }
  for (const t of s.thresholds.filter((x) => !x.ok)) {
    lines.push(`FAIL  ${t.metric}: ${t.expression}`);
  }
  return `${lines.join("\n")}\n`;
}

export function summary(data) {
  const metrics = {};
  for (const [name, m] of Object.entries(data.metrics)) {
    if (kept.test(name)) {
      metrics[name] = { type: m.type, contains: m.contains, values: m.values, thresholds: m.thresholds };
    }
  }
  const thresholds = thresholdRows(metrics);
  const checks = checkRows(data.root_group);
  const routeList = routeRows(metrics);
  // k6 skips a threshold whose metric got no sample: a run that stopped in setup() would pass every threshold. It passes
  // only when the load phase made requests.
  const loadRequests = routeList.reduce((n, r) => n + r.requests, 0);
  const s = {
    profile: profile.name,
    finished_at: new Date().toISOString(),
    test_run_duration_ms: data.state.testRunDurationMs,
    conditions: conditions(),
    thresholds_ok: loadRequests > 0 && thresholds.every((t) => t.ok),
    load_requests: loadRequests,
    thresholds,
    routes: routeList,
    dropped_iterations: metrics.dropped_iterations ? metrics.dropped_iterations.values.count : 0,
    checks: {
      passes: checks.reduce((n, c) => n + c.passes, 0),
      fails: checks.reduce((n, c) => n + c.fails, 0),
      list: checks,
    },
    metrics,
  };
  const results = (__ENV.SVP_K6_RESULTS || "").trim();
  if (results !== "") {
    return { stdout: text(s), [`${results.replace(/\/+$/, "")}/summary.json`]: `${JSON.stringify(s, null, 2)}\n` };
  }
  return { stdout: `${text(s)}svp-k6-summary ${JSON.stringify(s)}\n` };
}
