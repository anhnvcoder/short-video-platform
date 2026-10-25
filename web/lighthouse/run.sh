#!/usr/bin/env bash
# `make web-lighthouse`, run from web/ on the compose stack of `make up`: one Lighthouse run (@lhci/cli) of each of two
# pages in Playwright's Chromium, with Lighthouse's default mobile settings (an emulated phone, simulated slow 4G and a
# 4x CPU slowdown; Lighthouse has no preset named mobile, its desktop preset is the other one):
# - the feed, /, logged in: a fresh user, registered at the gateway, logs in through the web's login page
#   (lighthouse/session.ts) and Lighthouse sends that session cookie with every request (extraHeaders);
# - /v/{id} of a READY video, logged out: the newest video of explore, or, when explore is empty, a 4 s test clip the
#   user publishes first.
# Then a table of LCP, CLS, TBT and the LCP element of each page, the page's console errors, and `lhci assert` against
# the thresholds of lighthouse/lighthouserc.json: LCP
# 2500 ms, CLS 0.1, TBT 200 ms. The reports, HTML and JSON per page and manifest.json, go to test-results/lighthouse/
# (gitignored); nothing is uploaded anywhere. One run has noise (Lighthouse advises the median of several): compare
# runs on the same machine, do not read one as a commitment. Exits with the status of lhci assert.
#
# The cookie stays out of the output and the reports: Lighthouse reads it from a private file, the copy every result
# records (configSettings.extraHeaders) is replaced before the reports are written, the run fails when a cookie value
# is still found in a result or a report, and the session is logged out at exit so the cookie stops working.
#
# LOCAL LAB ONLY: sourcing deploy/compose/lib.sh deletes the gateway's register rate limit keys (svp:gw:rl:register:*)
# in Redis db 10 on 127.0.0.1:6379 with SCAN + DEL, as e2e/seed.sh and `make smoke` do. Never point it at a shared stack.
set -euo pipefail

base=http://127.0.0.1:8080
web_url=http://localhost:3001
web_dir=$PWD
rc=$web_dir/lighthouse/lighthouserc.json
lhci=$web_dir/node_modules/.bin/lhci
reports=$web_dir/test-results/lighthouse
# lhci keeps its results in .lighthouseci of the folder it runs in; that is this one, inside the gitignored reports.
lhci_dir=$reports/.lighthouseci
# shellcheck source=deploy/compose/lib.sh
source "$(dirname "$0")/../../deploy/compose/lib.sh"

# Replaces the EXIT trap of lib.sh: logs the session out (POST /logout with the web's own origin, as its CSRF check
# wants), so the cookie Lighthouse used no longer works, then removes lhci's results (the reports are the record) and
# the work folder as lib.sh does.
cleanup() {
  local status
  if [[ -f $work/cookie.txt ]]; then
    status=$(curl -sS --max-time "$max_time" -o /dev/null -w '%{http_code}' -X POST -H "Origin: $web_url" \
      -H "@$work/cookie.txt" "$web_url/logout" || true)
    if [[ $status == 303 ]]; then ok "logged the Lighthouse session out"; else
      echo "warn  logout answered $status: the session ends with its TTL" >&2
    fi
  fi
  rm -rf "$lhci_dir" "$work"
}
trap cleanup EXIT

[[ -x $lhci ]] || fail "lhci not found in web/node_modules (make web-install)"
chrome=$(node --input-type=module -e 'import { chromium } from "@playwright/test"; console.log(chromium.executablePath())')
[[ -x $chrome ]] || fail "Playwright's Chromium not found (in web/: pnpm exec playwright install chromium)"

wait_gateway_ready 60
new_user viewer

status=$(request GET "/feed/explore?page_size=1" "$work/viewer.auth")
[[ $status == 200 ]] || fail "read explore (status $status, $(problem_summary))"
video_id=$(jq -r '.items[0].video_id // ""' "$work/body")
if [[ -z $video_id ]]; then
  make_video "$work/clip.mp4" 4 360x640
  create_video clip "$work/viewer.auth" "lighthouse clip" "$(file_size "$work/clip.mp4")" video/mp4
  status=$(upload_file clip "$work/clip.mp4")
  [[ $status == 2?? ]] || fail "upload the test clip to the presigned form (status $status, code $(storage_error_code))"
  status=$(complete_upload clip "$work/viewer.auth")
  [[ $status == 202 ]] || fail "complete the upload of the test clip (status $status, $(problem_summary))"
  wait_ready clip "$work/viewer.auth" 180
  # shellcheck disable=SC2154 # clip_id and clip_wait are set by create_video and wait_ready of lib.sh
  video_id=$clip_id
  ok "explore was empty: published a test clip (READY after ${clip_wait} s)"
fi
ok "READY video for /v/{id}: $video_id"

node lighthouse/session.ts "$web_url" "$work/viewer.cred" "$work"
# The values a leak check looks for: every cookie value of 16 characters or more (the session id; a short one such as
# a language is no secret and would match unrelated text).
jq -r '.Cookie | split("; ")[] | sub("^[^=]*="; "") | select(length >= 16)' "$work/headers.json" >"$work/cookie-values"
[[ -s $work/cookie-values ]] || fail "the login set no session cookie"

mkdir -p "$reports"
cd "$reports"
"$lhci" collect --config="$rc" --chromePath="$chrome" --url="$web_url/" --settings.extraHeaders="$work/headers.json"
"$lhci" collect --config="$rc" --chromePath="$chrome" --url="$web_url/v/$video_id" --additive

shopt -s nullglob
results=("$lhci_dir"/lhr-*.json)
((${#results[@]} == 2)) || fail "expected 2 Lighthouse results, found ${#results[@]}"
# The feed was measured logged in: Lighthouse read the cookie file, and / did not redirect to /login.
jq -se --arg u "$web_url/" 'map(select(.requestedUrl == $u)) | length == 1 and
  (.[0].configSettings.extraHeaders | type) == "object" and .[0].finalDisplayedUrl == $u' "${results[@]}" >/dev/null ||
  fail "the feed was not measured logged in (no session cookie sent, or / redirected to /login)"
for result in "${results[@]}"; do
  jq '.configSettings.extraHeaders |= (if type == "object" then map_values("[redacted]") else . end)' "$result" \
    >"$work/lhr.json"
  mv "$work/lhr.json" "$result"
done
# The HTML lhci wrote next to each result embeds the result as it was; lhci upload writes the reports again from the
# redacted results.
rm -f "$lhci_dir"/lhr-*.html
"$lhci" upload --config="$rc" --outputDir="$reports"

written=()
while IFS= read -r path; do written+=("$path"); done < <(jq -r '.[] | .htmlPath, .jsonPath' "$reports/manifest.json")
if grep -qF -f "$work/cookie-values" "${results[@]}" "${written[@]}"; then
  rm -f "${written[@]}"
  fail "a session cookie value is still in a Lighthouse result or report (reports of this run removed)"
fi

echo "web-lighthouse (Lighthouse mobile, one run per page):"
jq -rs --arg origin "$web_url" '.[] |
  "  \(.requestedUrl | ltrimstr($origin)): LCP \(.audits["largest-contentful-paint"].numericValue | round) ms," +
  " CLS \(.audits["cumulative-layout-shift"].numericValue * 1000 | round / 1000)," +
  " TBT \(.audits["total-blocking-time"].numericValue | round) ms",
  "    LCP element: \(.audits["largest-contentful-paint-element"].details.items[0].items[0].node |
    if . == null then "none" else "\(.selector): \(.snippet)" end)",
  "    console errors: \(.audits["errors-in-console"].details.items // [] | length)",
  ((.audits["errors-in-console"].details.items // [])[] | "      \(.source): \(.description)")' "${results[@]}"
echo "  reports in web/test-results/lighthouse/ (manifest.json lists them)"

"$lhci" assert --config="$rc"
