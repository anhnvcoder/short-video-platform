import exec from "k6/execution";
import { routes } from "./lib/config.js";
import { send } from "./lib/http.js";

// Scenarios of the gateway's API, one per route of the SLOs.

// turn(data): this iteration's user and, for the routes that need one, its video. The users of the pool take turns in
// order (iterationInInstance counts this instance's iterations of the scenario, so on a cloud pod, which runs only its
// execution segment, the turn still goes through the whole of its own pool). The video moves on with each turn of the
// same user, from an offset of its own: taken from the iteration modulo the number of videos, as the user is, the two
// would turn in lockstep and a user would see only videos / gcd(users, videos) of them (5 of 30 with 12 users),
// repeating the (user, video) pairs that RL-3 stops at the gateway.
function turn(data) {
  const i = exec.scenario.iterationInInstance;
  const users = data.tokens.length;
  const user = i % users;
  return {
    headers: { Authorization: `Bearer ${data.tokens[user]}` },
    video: data.videos[(Math.floor(i / users) + user) % data.videos.length],
  };
}

export function feedExplore(data) {
  send("GET", `${data.targets.apiURL}/feed/explore`, null, routes.explore, { headers: turn(data).headers });
}

export function feedFollowing(data) {
  send("GET", `${data.targets.apiURL}/feed/following`, null, routes.following, { headers: turn(data).headers });
}

// Idempotent: liking a video again answers 204 too.
export function like(data) {
  const { headers, video } = turn(data);
  send("PUT", `${data.targets.apiURL}/videos/${video}/like`, null, routes.like, { headers });
}

// A user views the next video on each of its turns, so the gateway passes a view on to engagement-service only while
// the user's views in 60 s stay within the READY videos there are (RL-3 answers 202 for the rest without counting):
// with few videos (compose) the route is measured, the counting path only partly.
export function view(data) {
  const { headers, video } = turn(data);
  send("POST", `${data.targets.apiURL}/videos/${video}/views`, null, routes.view, { headers });
}

// Upload init only: no file is sent, so each call leaves an UPLOADING video that the upload sweep turns FAILED an hour
// later. The rate keeps each user under the 3 open uploads per 15 minutes of video-service (UP-7).
export function uploadInit(data) {
  const body = JSON.stringify({ title: "k6 load test", size_bytes: 1048576, content_type: "video/mp4" });
  send("POST", `${data.targets.apiURL}/videos`, body, routes.upload, {
    headers: { ...turn(data).headers, "Content-Type": "application/json" },
  });
}
