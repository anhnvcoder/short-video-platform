// Load test of the SLOs (docs/adr/0020-reliability-stage6.md, section 2): the API scenarios of api.js and the web
// scenarios of web.js in one k6 process, at the rates of the profile SVP_K6_PROFILE picks (local, ci, cloud; see
// lib/config.js). Run it through make load-local / make load-ci (deploy/k6/load.sh) or the cloud Job
// (deploy/k6/cloud/), never with a k6 that is not K6_IMAGE.
//
// Environment: SVP_K6_PROFILE; SVP_API_URL (the gateway), SVP_WEB_URL (the address k6 dials for the web client) and
// SVP_WEB_ORIGIN (the origin users open it at, sent as Host and Origin); SVP_K6_HOLD (how long the full rate holds,
// default per profile); SVP_K6_RESULTS (the folder summary.json goes to; unset: stdout); SVP_K6_FORWARDED_FOR (cloud
// Job only, see lib/config.js).
import { scenarios, thresholds } from "./lib/config.js";
import { createPool } from "./lib/setup.js";
import { summary } from "./lib/summary.js";
import { feedExplore, feedFollowing, like, uploadInit, view } from "./api.js";
import { home, loginPage, sharePage } from "./web.js";

export { feedExplore, feedFollowing, like, view, uploadInit, home, sharePage, loginPage };

export const options = {
  scenarios: scenarios({
    explore: "feedExplore",
    following: "feedFollowing",
    like: "like",
    view: "view",
    upload: "uploadInit",
    home: "home",
    video: "sharePage",
    login: "loginPage",
  }),
  thresholds: thresholds(),
  // Registering and logging in a pool user hashes a password twice (argon2id) at user-service.
  setupTimeout: "3m",
  summaryTrendStats: ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)", "count"],
  // Bodies are read only where setup() needs them (responseType "text"); the load discards them.
  discardResponseBodies: true,
};

export function setup() {
  return createPool();
}

export function handleSummary(data) {
  return summary(data);
}
