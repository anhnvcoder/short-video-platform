# shellcheck shell=bash
# Scenario compose-obs of deploy/ci/verify-run.sh, which sources this file: the compose stack with OBS=lgtm (job compose
# of .github/workflows/verify.yml). make up OBS=lgtm, make smoke, make drill-duplicates and make drill-kill-worker (the
# versioned HLS output: a replayed video.uploaded writes nothing, a worker killed mid-transcode leaves no published key
# of its own; both start every service again), make drill-obs-threats, make load-local under a watch of Alertmanager,
# make web-lighthouse three times; then the object store's checks (make test-stack of
# internal/objstore, make drill-upload-cleanup, make measure-upload with the store's RAM peak); make
# drill-alert-to-sentry; last, the way back to MinIO and make smoke on RustFS again.
#
# Steps that are not a make target of their own, all reading what the targets left:
#   load-local                 waits until Alertmanager has no RateLimitFallbackActive alert (drill-obs-threats makes
#                              it fire on purpose), polls Alertmanager every 10 s through make load-local and 150 s
#                              after it (the rule's 2 m window and a margin), counting the polls it answered and those
#                              it did not, then reads from Prometheus (Grafana's datasource proxy) the gateway's p99
#                              Redis command time, its Redis commands that timed out, and its rate limit decisions, all
#                              and on the fallback counter, over the load, counting the queries it did not answer;
#                              rate-limit-load.json. Its exit status is that of make load-local
#   fallback-alert-under-load  fails when an alert RateLimitFallbackActive started during that window, and also when
#                              the evidence is missing: a poll of Alertmanager or a query of Prometheus that got no
#                              answer (Alertmanager lists an alert only while it fires, so a gap could hide one), or no
#                              rate limit decision of the gateway over the load. On the runner Redis is reached over
#                              Linux's bridge, not Docker Desktop's host.docker.internal, so a clean result is weak
#                              evidence; the promtool tests of the rule are the main check
#   web-lighthouse-<n>         make web-lighthouse, its manifest.json kept as manifest-<n>.json
#   lcp                        median LCP of / and /v/{id} over the three runs, with Lighthouse's benchmarkIndex;
#                              lcp.json; fails when a median is over 2500 ms
#   test-stack-objstore        make test-stack PKGS=./internal/objstore/... (go test -race -count=1 -v against the
#                              stack's object store), its output counted: fails when go test fails, when any test or
#                              subtest SKIPs (a skipped case proves nothing about the store), or when one of the
#                              integration tests (presigned POST, worker and video-service permissions, DeletePrefix,
#                              multipart with CRC32, Cache-Control read back anonymously, create only once, the
#                              worker listing and reading media/) did not PASS
#   ram-s3-upload              deploy/ci/verify-sample.sh s3-peak over the samples taken while measure-upload ran: the
#                              highest MEM USAGE of the object store's container while ~100 MB went up from the browser
#                              and transcoded; ram-s3-upload.json, .txt; fails when it is not under its 512 MiB limit or
#                              no sample saw it. Skipped when measure-upload did not run
#   object-store-roundtrip     the way back to MinIO, tried on this runner's data: searches the log of s3-init (make up
#                              ran it) for every secret value of .env (only counts printed), waits until no video
#                              is PROCESSING (SELECT on svp_video), takes one sample of verify-sample.sh when it keeps
#                              samples (the compose containers' restarts, which make down removes with them), make
#                              down, make object-store-copy TO=minio (into a new volume svp_minio-data of the runner),
#                              which must pass and name no READY video's key lost, with at least one READY video made
#                              on RustFS by the targets before; then, passed or not, make up OBS=lgtm again on RustFS
#                              (s3-init a second time, on a store it already initialised: its log searched the same
#                              way) and make smoke. Last: it stops and starts the whole stack, so a target after it
#                              would run on another stack than in earlier runs

build=up
job_minutes_default=120
k3d=0

# --- Steps of their own; exported, since timeout runs them in a new bash.

# load_local_watch: see load-local in the header. Runs in a bash of its own (timeout), without this script's options.
load_local_watch() {
  local am=http://127.0.0.1:9093/api/v2/alerts prom=http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus
  local filter='alertname="RateLimitFallbackActive"' tmp start end rc poller deadline cleared=false w m redis
  local q_p99 q_timeouts q_fallback q_decisions p99 timeouts fallback decisions prom_failed=0
  tmp=$(mktemp -d)
  # am_alerts FILE [CURL ARGS...]: the alerts of RateLimitFallbackActive into FILE as one JSON list; fails when
  # Alertmanager does not answer with one.
  am_alerts() {
    local file=$1
    shift
    curl -sS -G --fail --max-time 10 "$am" --data-urlencode "filter=$filter" "$@" -o "$file.raw" &&
      jq -c 'if type == "array" then . else error("not a list of alerts") end' "$file.raw" >"$file"
  }
  # am_poll: one poll of the watch: its alerts appended to alerts.jsonl, "<time> ok" or "<time> failed" to polls.
  am_poll() {
    if am_alerts "$tmp/poll"; then
      jq -c '.[]' "$tmp/poll" >>"$tmp/alerts.jsonl"
      echo "$(date +%s) ok" >>"$tmp/polls"
    else
      echo "$(date +%s) failed" >>"$tmp/polls"
    fi
  }
  deadline=$(($(date +%s) + 300))
  while :; do
    if am_alerts "$tmp/now" --data-urlencode active=true --data-urlencode silenced=false \
      --data-urlencode inhibited=false && [ "$(jq length "$tmp/now")" = 0 ]; then
      cleared=true
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "RateLimitFallbackActive still active (or Alertmanager not answering) after 300 s; load starts anyway"
      break
    fi
    sleep 10
  done
  : >"$tmp/polls"
  start=$(date +%s)
  (while :; do
    am_poll
    sleep 10
  done) &
  poller=$!
  make load-local
  rc=$?
  end=$(date +%s)
  echo "make load-local: exit $rc; watching Alertmanager 150 s more"
  sleep 150
  kill "$poller" 2>/dev/null
  wait "$poller" 2>/dev/null
  am_poll
  # promql EXPR: the value of the first sample at the end of the load, "none" when the query has no sample; fails when
  # Prometheus does not answer it.
  promql() {
    curl -sS -G --fail --max-time 20 "$prom/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$end" \
      -o "$tmp/prom.json" &&
      jq -r 'if .status == "success" then (.data.result[0].value[1] // "none") else error("query failed") end' \
        "$tmp/prom.json"
  }
  # Each query built first: a selector such as {a="x",b="y"} inside a nested "$(... "...")" is brace-expanded by bash.
  w=$((end - start))
  m=db_client_connections_use_time_milliseconds
  redis='service_name="gateway",db_system="redis"'
  printf -v q_p99 'histogram_quantile(0.99, sum by (le) (increase(%s_bucket{%s,type="command"}[%ss])))' "$m" "$redis" "$w"
  printf -v q_timeouts 'sum(increase(%s_count{%s,error_type="context_timeout"}[%ss]))' "$m" "$redis" "$w"
  printf -v q_fallback 'sum(increase(svp_ratelimit_decisions_total{service_name="gateway",store="fallback"}[%ss]))' "$w"
  printf -v q_decisions 'sum(increase(svp_ratelimit_decisions_total{service_name="gateway"}[%ss]))' "$w"
  p99=$(promql "$q_p99") || { p99=null prom_failed=$((prom_failed + 1)); }
  timeouts=$(promql "$q_timeouts") || { timeouts=null prom_failed=$((prom_failed + 1)); }
  fallback=$(promql "$q_fallback") || { fallback=null prom_failed=$((prom_failed + 1)); }
  decisions=$(promql "$q_decisions") || { decisions=null prom_failed=$((prom_failed + 1)); }
  jq -n --argjson start "$start" --argjson end "$end" --argjson rc "$rc" --argjson cleared "$cleared" \
    --slurpfile alerts <(cat "$tmp/alerts.jsonl" 2>/dev/null) --rawfile polls "$tmp/polls" \
    --arg p99 "$p99" --arg timeouts "$timeouts" --arg fallback "$fallback" --arg decisions "$decisions" \
    --argjson prom_failed "$prom_failed" --argjson watched "$(($(date +%s) - start))" '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    # A value of Prometheus: a number, "none" (the query had no sample) or null (Prometheus did not answer).
    def value: if . == "null" then null else (tonumber? // .) end;
    ($alerts | map(select((.startsAt | epoch) >= $start)) | unique_by(.fingerprint)) as $new |
    ($polls | split("\n") | map(select(length > 0) | split(" ")[1])) as $p |
    {
      load_start: ($start | todate), load_end: ($end | todate), watched_seconds: $watched, load_local_exit: $rc,
      alertmanager: {cleared_before_load: $cleared, polls_ok: ($p | map(select(. == "ok")) | length),
        polls_failed: ($p | map(select(. == "failed")) | length)},
      prometheus_queries_failed: $prom_failed,
      fallback_alerts: ($new | length),
      fallback_alerts_started: ($new | map(.startsAt)),
      gateway_redis_command_p99_ms: ($p99 | value), gateway_redis_context_timeouts: ($timeouts | value),
      gateway_fallback_decisions: ($fallback | value), gateway_rate_limit_decisions: ($decisions | value),
      note: "Redis is reached over the Linux bridge on the runner, not host.docker.internal of Docker Desktop: no false page here is weak evidence; the promtool tests of the rule are the main check"
    }' >"$SVP_VERIFY_OUT/rate-limit-load.json"
  rm -rf "$tmp"
  cat "$SVP_VERIFY_OUT/rate-limit-load.json"
  return "$rc"
}

# fallback_alert_check: see fallback-alert-under-load in the header; one line per reason it fails.
fallback_alert_check() {
  local problems
  problems=$(jq -r '
    (if .alertmanager.polls_ok == 0 then "Alertmanager answered no poll during the load" else empty end),
    (if .alertmanager.polls_failed > 0
      then "Alertmanager did not answer \(.alertmanager.polls_failed) poll(s): an alert could have fired unseen"
      else empty end),
    (if .prometheus_queries_failed > 0 then "Prometheus did not answer \(.prometheus_queries_failed) query(ies)"
      else empty end),
    (if (.gateway_rate_limit_decisions | type) != "number" or .gateway_rate_limit_decisions <= 0
      then "Prometheus shows no rate limit decision of the gateway over the load" else empty end),
    (if .fallback_alerts > 0 then "RateLimitFallbackActive started \(.fallback_alerts) time(s) during the load"
      else empty end)' "$SVP_VERIFY_OUT/rate-limit-load.json") || {
    echo "FAIL  no rate-limit-load.json to read (load-local did not finish)"
    return 1
  }
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed 's/^/FAIL  /'
    return 1
  fi
  echo "ok    no RateLimitFallbackActive started during the load; Alertmanager answered every poll"
}

# lighthouse_run N: make web-lighthouse, its manifest kept as manifest-N.json (each run writes manifest.json anew).
lighthouse_run() {
  local rc dir=web/test-results/lighthouse
  make web-lighthouse
  rc=$?
  [ -f "$dir/manifest.json" ] && mv "$dir/manifest.json" "$dir/manifest-$1.json"
  return "$rc"
}

# lcp_median: see lcp in the header.
lcp_median() {
  local dir=web/test-results/lighthouse reports
  reports=$(jq -r '.[].jsonPath' "$dir"/manifest-*.json) || return 1
  [ -n "$reports" ] || { echo "no Lighthouse report"; return 1; }
  # shellcheck disable=SC2086 # one path per line, none with a blank (lhci names them)
  jq -s '
    def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor]
      else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    map({page: (.requestedUrl | sub("^https?://[^/]+"; "") | if startswith("/v/") then "/v/{id}" else . end),
      lcp: .audits["largest-contentful-paint"].numericValue, benchmark: .environment.benchmarkIndex})
    | group_by(.page) | map({page: .[0].page, runs: length, lcp_median_ms: (map(.lcp) | median | round),
      lcp_ms: map(.lcp | round), benchmark_index: map(.benchmark), within_2500_ms: ((map(.lcp) | median) <= 2500)})' \
    $reports >"$SVP_VERIFY_OUT/lcp.json" || return 1
  cat "$SVP_VERIFY_OUT/lcp.json"
  jq -e 'length > 0 and all(.within_2500_ms)' "$SVP_VERIFY_OUT/lcp.json" >/dev/null
}

# objstore_tests: see test-stack-objstore in the header.
objstore_tests() {
  local tmp rc passes fails skips missing= t
  tmp=$(mktemp)
  make test-stack PKGS=./internal/objstore/... 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  passes=$(grep -cE '^ *--- PASS: ' "$tmp")
  fails=$(grep -cE '^ *--- FAIL: ' "$tmp")
  skips=$(grep -cE '^ *--- SKIP: ' "$tmp")
  for t in TestIntegrationPresignedPost TestIntegrationWorkerPermissions TestIntegrationVideoServicePermissions \
    TestIntegrationDeletePrefix TestIntegrationMultipartChecksum TestIntegrationCacheControl TestIntegrationCreateOnce \
    TestIntegrationWorkerReadsMedia; do
    grep -qE "^--- PASS: $t " "$tmp" || missing="$missing $t"
  done
  rm -f "$tmp"
  echo "object store tests: $passes passed, $fails failed, $skips skipped (tests and subtests); make test-stack exit $rc"
  [ -z "$missing" ] || echo "FAIL  did not pass:$missing"
  [ "$skips" = 0 ] || echo "FAIL  $skips test(s) skipped: every test of the object store must run against it"
  [ "$rc" = 0 ] && [ "$fails" = 0 ] && [ "$skips" = 0 ] && [ -z "$missing" ]
}

# s3_init_log WHICH: the log of the s3-init container (each of its runs since the last make down), counted and searched
# for every secret value of .env, never printed (no service log reaches the job's log or the artifact); fails when it
# has no line, when a value is in it, or without the list to search with.
s3_init_log() {
  local log lines hits list=$SVP_VERIFY_SECRETS/env.values
  [ -s "$list" ] || { echo "FAIL  s3-init ($1): no secret list to search its log with"; return 1; }
  log=$(make -s logs SVC=s3-init 2>&1) || { echo "FAIL  s3-init ($1): make logs SVC=s3-init failed"; return 1; }
  lines=$(printf '%s\n' "$log" | grep -c .)
  hits=$(printf '%s\n' "$log" | grep -cF -f "$list")
  echo "s3-init ($1): $lines log line(s), $hits with a secret value of .env"
  [ "$lines" -gt 0 ] && [ "$hits" = 0 ]
}

# object_store_roundtrip: see object-store-roundtrip in the header.
object_store_roundtrip() {
  local rc=0 ready processing deadline copy_out lost
  # The Postgres of the runner is a service container of the job with the password postgres; object-store-copy.sh
  # connects with -w and takes the password from the environment, as deploy/postgres/bootstrap.sh does.
  export PGPASSWORD=${PGPASSWORD:-postgres}
  pg() { psql -h 127.0.0.1 -p 5432 -U postgres -d svp_video -w -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }
  s3_init_log "before the copy" || rc=1
  # Nothing may write to the store while it is copied: no upload runs between targets, and a transcode still going
  # ends within minutes (the copy refuses while one is PROCESSING).
  deadline=$(($(date +%s) + 300))
  until processing=$(pg "SELECT count(*) FROM videos WHERE status = 'PROCESSING'") && [ "$processing" = 0 ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "videos still PROCESSING after 300 s: ${processing:-unknown} (object-store-copy refuses then)"
      break
    fi
    sleep 10
  done
  ready=$(pg "SELECT count(*) FROM videos WHERE status = 'READY'") || ready=
  echo "videos READY in svp_video, made on RustFS by the targets before: ${ready:-unknown}"
  case $ready in '' | 0) echo "FAIL  no READY video: the copy would prove nothing about the objects of one"; rc=1 ;; esac
  # The sampler reads restarts every 10 s; one reading now keeps a restart since its last one, as make down removes the
  # containers and make up makes them anew with a count of 0.
  if [ -d "$SVP_VERIFY_OUT/samples" ]; then
    "$here/verify-sample.sh" sample || echo "verify-sample.sh sample failed"
  fi
  make down || { echo "FAIL  make down"; return 1; }
  copy_out=$(mktemp)
  make object-store-copy TO=minio 2>&1 | tee "$copy_out"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL  make object-store-copy TO=minio"; rc=1; }
  lost=$(sed -n "s/^object-store-copy: READY videos' keys lost before this copy: //p" "$copy_out")
  rm -f "$copy_out"
  [ "$lost" = 0 ] || { echo "FAIL  READY videos' keys lost: ${lost:-not reported}"; rc=1; }
  # The stack runs on RustFS again whatever the copy did: the copy never changes the store the stack uses.
  make up OBS=lgtm || { echo "FAIL  make up OBS=lgtm after the copy"; return 1; }
  s3_init_log "after the copy, on a store already initialised" || rc=1
  make smoke || { echo "FAIL  make smoke after the copy"; rc=1; }
  return "$rc"
}

export -f load_local_watch fallback_alert_check lighthouse_run lcp_median objstore_tests s3_init_log \
  object_store_roundtrip

scenario_targets() {
  step up 40 make up OBS=lgtm
  step smoke 15 make smoke
  # Both drills read the outbox of svp_video with psql -w: the Postgres of the runner is a service container of the job
  # with the password postgres (as object-store-roundtrip below).
  step drill-duplicates 15 env PGPASSWORD=postgres make drill-duplicates
  step drill-kill-worker 20 env PGPASSWORD=postgres make drill-kill-worker
  step drill-obs-threats 30 make drill-obs-threats
  step load-local 25 bash -c load_local_watch
  step fallback-alert-under-load 1 bash -c fallback_alert_check
  for i in 1 2 3; do step "web-lighthouse-$i" 10 bash -c 'lighthouse_run "$1"' _ "$i"; done
  step lcp 1 bash -c lcp_median
  # The object store's own checks after the targets above, which so run as in the runs before the store changed.
  step test-stack-objstore 20 bash -c objstore_tests
  step drill-upload-cleanup 15 make drill-upload-cleanup
  step measure-upload 25 make measure-upload
  if [ "$last_status" = skipped ]; then
    skip ram-s3-upload "measure-upload did not run"
  else
    step ram-s3-upload 2 "$here/verify-sample.sh" s3-peak "$last_start" "$last_end"
  fi
  # An extra on top of the scenario's main sequence, and the longest wait (an alert of an earlier run must resolve
  # first).
  step drill-alert-to-sentry 40 make drill-alert-to-sentry
  # Last: it takes the stack down and up again (see the header). The scenario takes about 55 min of the 70 its
  # deadline leaves (the two drills after smoke about 10 of them), so the deadline cutting it means something else ran
  # far over.
  step object-store-roundtrip 40 bash -c object_store_roundtrip
}
