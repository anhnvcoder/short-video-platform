#!/usr/bin/env bash
# Shows that Tempo of cluster k3d-svp still takes in and serves traces under the load of a verification step: Tempo
# runs with a memory limit and an ingest ceiling, so it may refuse spans, and not being OOM-killed is not enough. Run
# by the steps tempo-ingest-<n> of deploy/ci/verify/k6-cloud-mini.sh and tempo-ingest-chaos-<x> of
# deploy/ci/verify/chaos.sh (through deploy/ci/verify-run.sh), each right after the step whose k6 load it reads.
#
#   verify-tempo.sh LABEL   LABEL is the hold window's label in $SVP_VERIFY_OUT/k6-windows.tsv (k6-pods-<n>,
#                           chaos-<x>; the last line of that label); writes .k8s/drills/tempo-ingest-LABEL-<time>.json
#                           and a table; exits 0 when the label passed, 1 otherwise
#   verify-tempo.sh test    the self-test: fake kubectl, curl and nc first on PATH, fixtures in a temporary directory,
#                           no cluster, no network (deploy/ci/verify-collect-test.sh runs it); also on macOS
#
# Over the window [start, end] of the label:
#   Collector   the cluster's Prometheus (a port-forward on 127.0.0.1:19090 to service kps-prometheus, as the drills
#               open it), where the Collector pushes its own metrics every 15 s (service_name otelcol, as the USE
#               dashboard selects it). In: the spans the receivers accepted, refused and failed, summed over every
#               receiver and transport (the traces pipeline has receiver otlp; memory_limiter heads the pipeline, so
#               data it refuses is counted refused at the receiver, never reaching the exporter):
#               otelcol_receiver_accepted_spans_total, otelcol_receiver_refused_spans_total,
#               otelcol_receiver_failed_spans_total. Out, exporter otlp_grpc/tempo: otelcol_exporter_sent_spans_total
#               (and its rate, spans per second over the window), otelcol_exporter_send_failed_spans_total,
#               otelcol_exporter_enqueue_failed_spans_total.
#   Tempo       its own /metrics (a port-forward on 127.0.0.1:13200 to pod svp-obs/tempo-0, port 3200, as
#               drill-k8s-web-obs opens Tempo; Prometheus does not scrape Tempo), read when this runs: counters since
#               the container started, so read with the restartCount and start of container tempo.
#               tempo_distributor_spans_received_total (spans past the ingest limit), tempo_discarded_spans_total by
#               reason (rate_limited at the distributor; live_traces_exceeded, trace_too_large, unknown_error in the
#               live store), tempo_live_store_live_traces (a gauge).
#   Read back   a TraceQL search, { resource.service.name = "gateway" } over the window, then the first traces found
#               that started in it (5 at most) fetched by id (/api/traces/<id>) until one holds spans of 2 services or
#               more; the service graph, traces_service_graph_request_total{client="gateway",server="feed-service"}
#               (written to Prometheus by Tempo's metrics-generator), grown over the window.
#
# A series that is not there is unmeasured, never 0, except where the counter only exists once it has counted: the
# Collector creates otelcol_exporter_send_failed_* and otelcol_exporter_enqueue_failed_* at the first failure
# (exporterhelper v0.162.0: obs_report_sender.go adds failures only when there are some, queue/obs_queue.go only on a
# refused offer), and Tempo creates a tempo_discarded_spans_total series at the first discard of its reason (Tempo
# v3.1.0 modules/overrides/discarded_spans.go). Those read 0 when absent while their companion (sent spans, received
# spans) is there. The receivers' accepted, refused and failed counters are added to, 0 included, on every request
# (receiverhelper v0.162.0 obsreport.go recordMetrics), so their absence is unmeasured. A counter's growth over the
# window is the larger of increase() and its highest value in the window minus its value at the start (0 when absent
# there): increase() misses the first value of a series born inside the window.
#
# Criteria. k6-pods-1, -2, -4 and chaos-*: the receivers refused and failed no span (a refused span may still have been
# retried by an SDK, which this cannot see, so a refusal is never read as "nothing lost"); the exporter failed to send
# and failed to queue no span; Tempo discarded no span in the run, read from counters that cover the window (container
# tempo with restartCount 0, started before the window; otherwise the counters reset and say nothing: fail); a trace
# found and fetched with 2 services or more; a gateway -> feed-service edge grown in the service graph. Every source
# measured: a source unmeasured fails with the reason "unmeasured". k6-pods-8 (past the load measured to fit): the
# numbers only, always passes. Any other label stops the script (exit 2).
#
# The JSON holds counts, trace ids, service names and span counts only: no span attribute, no URL, no header. A taken
# port stops the script with that reason; no other port of localhost is tried. Each port-forward is stopped by the pid
# recorded when it started, also on INT and TERM (deploy/ci/verify-run.sh stops a step past its limit with TERM).
# kubectl names --context k3d-svp on every call.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

prom_port=19090
tempo_port=13200
# How many traces of the search are fetched at most, to find one with spans of 2 services.
tempo_fetch_max=5
# Seconds a port-forward gets to answer (the self-test shortens it).
forward_wait_s=20
collector_sel='service_name=~"otelcol|otelcol-contrib"'
exporter_sel="$collector_sel,exporter=\"otlp_grpc/tempo\""

kc() { kubectl --context k3d-svp --request-timeout=10s "$@"; }
# port_free PORT: true when nothing accepts connections on 127.0.0.1:PORT.
port_free() { ! nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1; }

forward_pids=
# forward TARGET LOCAL:REMOTE: a port-forward to TARGET of svp-obs on 127.0.0.1:LOCAL in the background, its pid
# recorded. kubectl itself, not kc: $! of a function in the background is a subshell's pid.
forward() {
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 "$1" "$2" >/dev/null 2>&1 &
  forward_pids="$forward_pids $!"
}
stop_forwards() {
  local pid
  for pid in $forward_pids; do
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  forward_pids=
}
# ready URL: true once URL answers, within forward_wait_s.
ready() {
  local i
  for i in $(seq 1 "$forward_wait_s"); do
    curl -sf --max-time 2 "$1" >/dev/null 2>&1 && return 0
    [ "$i" = "$forward_wait_s" ] || sleep 1
  done
  return 1
}

# prom QUERY TIME: .data.result of an instant query at TIME, compact JSON; fails when Prometheus did not answer.
prom() {
  local r
  r=$(curl -sf --max-time 20 "http://127.0.0.1:$prom_port/api/v1/query" --data-urlencode "query=$1" \
    --data-urlencode "time=$2") && jq -ce '.data.result' <<<"$r"
}

# counter SELECTOR: {"series": whether SELECTOR has a series in the window, "count": its growth over the window
# (see the header), summed}; null when Prometheus did not answer. Reads from, to and secs.
counter() {
  local a b c
  a=$(prom "sum(increase($1[${secs}s]))" "$to") && c=$(prom "sum(max_over_time($1[${secs}s]))" "$to") &&
    b=$(prom "sum($1)" "$from") || {
    echo null
    return
  }
  jq -nc --argjson a "$a" --argjson b "$b" --argjson c "$c" '
    def v: if length == 0 then null else .[0].value[1] | tonumber end;
    ($c | v) as $max |
    if $max == null then {series: false, count: null}
    else {series: true, count: ([($a | v // 0), $max - ($b | v // 0), 0] | max | round)} end'
}

# collector: the Collector's part (see the header), a JSON object; {"answered": false} without Prometheus.
collector() {
  local receivers accepted refused failed sent send_failed enqueue_failed graph
  receivers=$(prom "count by (receiver, transport) (otelcol_receiver_accepted_spans_total{$collector_sel})" "$to") ||
    receivers=null
  accepted=$(counter "otelcol_receiver_accepted_spans_total{$collector_sel}")
  refused=$(counter "otelcol_receiver_refused_spans_total{$collector_sel}")
  failed=$(counter "otelcol_receiver_failed_spans_total{$collector_sel}")
  sent=$(counter "otelcol_exporter_sent_spans_total{$exporter_sel}")
  send_failed=$(counter "otelcol_exporter_send_failed_spans_total{$exporter_sel}")
  enqueue_failed=$(counter "otelcol_exporter_enqueue_failed_spans_total{$exporter_sel}")
  graph=$(counter 'traces_service_graph_request_total{client="gateway",server="feed-service"}')
  jq -nc --argjson receivers "$receivers" --argjson accepted "$accepted" --argjson refused "$refused" \
    --argjson failed "$failed" --argjson sent "$sent" --argjson send_failed "$send_failed" \
    --argjson enqueue_failed "$enqueue_failed" --argjson graph "$graph" --argjson secs "$secs" '
    # A failure counter born at its first failure: 0 while absent, once its companion counter is there.
    def born($with): if . == null or $with == null or ($with.series | not) then . elif .series then . else {series: false, count: 0} end;
    {
      answered: ([$accepted, $refused, $failed, $sent, $send_failed, $enqueue_failed, $graph] | all(. != null)),
      receivers: (if $receivers == null then null else $receivers | map("\(.metric.receiver // "?")/\(.metric.transport // "?")") | sort end),
      receiver_accepted: $accepted, receiver_refused: $refused, receiver_failed: $failed,
      exporter: "otlp_grpc/tempo", exporter_sent: $sent,
      exporter_sent_per_second: (if $sent.series? then $sent.count / $secs * 10 | round / 10 else null end),
      exporter_send_failed: ($send_failed | born($sent)), exporter_enqueue_failed: ($enqueue_failed | born($sent)),
      service_graph_gateway_feed: $graph
    }'
}

# tempo_side: Tempo's part (see the header), a JSON object.
tempo_side() {
  local pod metrics=null m
  pod=$(kc -n svp-obs get pod tempo-0 -o json 2>/dev/null | jq -c '[.status.containerStatuses[]? | select(.name == "tempo")
    | {restart_count: .restartCount, started_at: (.state.running.startedAt // null),
       last_end: (.lastState.terminated.reason // null)}] | first // null') || pod=null
  if m=$(curl -sf --max-time 20 "http://127.0.0.1:$tempo_port/metrics"); then
    # Text format: name{labels} value; the values summed over tenants, the discards by reason.
    metrics=$(awk '
      /^#/ { next }
      { name = $1; sub(/\{.*/, "", name); value = $NF }
      name == "tempo_distributor_spans_received_total" { received += value; seen_received = 1 }
      name == "tempo_live_store_live_traces" { live += value; seen_live = 1 }
      name == "tempo_discarded_spans_total" {
        reason = "?"
        if (match($0, /reason="[^"]*"/)) reason = substr($0, RSTART + 8, RLENGTH - 9)
        discarded[reason] += value
      }
      END {
        printf "{\"spans_received\": %s, \"live_traces\": %s, \"discarded\": {", seen_received ? sprintf("%.0f", received) : "null",
          seen_live ? sprintf("%.0f", live) : "null"
        sep = ""
        for (r in discarded) { printf "%s\"%s\": %.0f", sep, r, discarded[r]; sep = ", " }
        print "}}"
      }' <<<"$m" | jq -c .) || metrics=null
  fi
  jq -nc --argjson pod "${pod:-null}" --argjson metrics "$metrics" \
    '{answered: ($metrics != null), container: $pod} + ($metrics // {})
      | .discarded_total = (if $metrics == null then null else [.discarded[]] | add // 0 end)'
}

# read_back: the search and the trace fetched (see the header), a JSON object.
read_back() {
  local search ids id trace services found=null
  if ! search=$(curl -sf --max-time 30 -G "http://127.0.0.1:$tempo_port/api/search" \
    --data-urlencode 'q={ resource.service.name = "gateway" }' --data-urlencode "start=$from" \
    --data-urlencode "end=$to" --data-urlencode limit=20) || ! jq -e . >/dev/null 2>&1 <<<"$search"; then
    echo '{"search_answered": false}'
    return
  fi
  ids=$(jq -r --argjson from "$from" --argjson to "$to" '[.traces[]? | select(.traceID | test("^[0-9a-f]+$"))
    | select((.startTimeUnixNano | tonumber) / 1e9 | . >= $from and . <= $to)] | sort_by(.startTimeUnixNano | tonumber)
    | .[].traceID' <<<"$search")
  for id in $(head -n "$tempo_fetch_max" <<<"$ids"); do
    trace=$(curl -sf --max-time 20 "http://127.0.0.1:$tempo_port/api/traces/$id") || continue
    # Tempo's JSON is OTLP: resource spans under batches (v1 API) or trace.resourceSpans, spans under scopeSpans.
    services=$(jq -c '[(.batches // .trace.resourceSpans // .resourceSpans // [])[]
      | {service: ([.resource.attributes[]? | select(.key == "service.name") | .value.stringValue][0] // "?"),
         spans: ([(.scopeSpans // [])[] | .spans[]?] | length)}]
      | group_by(.service) | map({key: .[0].service, value: (map(.spans) | add)}) | from_entries' <<<"$trace") || continue
    found=$(jq -nc --arg id "$id" --argjson s "$services" '{id: $id, services: $s}')
    [ "$(jq length <<<"$services")" -ge 2 ] && break
  done
  jq -nc --argjson n "$(grep -c . <<<"$ids")" --argjson found "$found" \
    '{search_answered: true, traces_in_window: $n, trace: $found}'
}

# verdict LABEL MODE: the criteria (see the header) over the JSON object on stdin; adds reasons and result.
verdict() {
  jq --arg mode "$1" '
    def unm($what): "unmeasured: \($what)";
    .collector as $c | .tempo as $t | .read as $r | .window.from as $from |
    [
      if ($c.answered | not) then unm("Prometheus did not answer") else
        (if ($c.receiver_accepted.series | not) then unm("no series otelcol_receiver_accepted_spans_total") else empty end),
        (if ($c.receiver_refused.series | not) then unm("no series otelcol_receiver_refused_spans_total") else empty end),
        (if ($c.receiver_failed.series | not) then unm("no series otelcol_receiver_failed_spans_total") else empty end),
        ((($c.receiver_refused.count // 0) + ($c.receiver_failed.count // 0)) as $n
          | if $n > 0 then "the Collector refused \($n) span(s) at its receivers (refused \($c.receiver_refused.count), failed \($c.receiver_failed.count))" else empty end),
        (if ($c.exporter_sent.series | not) then unm("no series otelcol_exporter_sent_spans_total of exporter otlp_grpc/tempo") else
          (($c.exporter_send_failed.count // 0) + ($c.exporter_enqueue_failed.count // 0)) as $n
          | if $n > 0 then "exporter otlp_grpc/tempo lost \($n) span(s) (send failed \($c.exporter_send_failed.count), not queued \($c.exporter_enqueue_failed.count))" else empty end end),
        (if ($c.service_graph_gateway_feed.series | not) then unm("no series traces_service_graph_request_total gateway -> feed-service")
          elif $c.service_graph_gateway_feed.count == 0 then "no gateway -> feed-service request grew in the service graph over the window" else empty end)
      end,
      if ($t.answered | not) then unm("Tempo /metrics did not answer")
      elif $t.spans_received == null then unm("no series tempo_distributor_spans_received_total in Tempo /metrics")
      elif $t.discarded_total > 0 then "Tempo discarded \($t.discarded_total) span(s) in the run (\($t.discarded | to_entries | map("\(.key) \(.value)") | join(", ")))"
      else empty end,
      if $t.container == null then unm("container tempo of pod svp-obs/tempo-0 not read")
      elif $t.container.restart_count != 0 or $t.container.started_at == null
        or ($t.container.started_at | fromdateiso8601) > $from then
        "Tempo counters do not cover the window: container tempo restartCount \($t.container.restart_count), started \($t.container.started_at // "not running")\(if $t.container.last_end then ", last ended \($t.container.last_end)" else "" end)"
      else empty end,
      if ($r.search_answered | not) then unm("Tempo search did not answer")
      elif $r.traces_in_window == 0 then "no trace with a span of gateway started in the window"
      elif $r.trace == null then "no trace of the search could be fetched by id"
      elif ($r.trace.services | length) < 2 then "no trace fetched holds spans of 2 services (\($r.trace.services | keys | join(", ")))"
      else empty end
    ] as $reasons |
    .mode = $mode | .reasons = $reasons
    | .result = (if $mode == "record" or ($reasons | length) == 0 then "pass" else "fail" end)'
}

# report FILE: the table of the step's output.
report() {
  jq -r '
    def n: if . == null then "-" else tostring end;
    def row($name; $v): "  \($name)\(" " * ([1, 44 - ($name | length)] | max))\($v)";
    "tempo-ingest \(.label): \(.result | ascii_upcase) (\(.mode)); window \(.window.from | todate) to \(.window.to | todate) (\(.window.seconds) s)",
    "  Collector receivers of traces: \(.collector.receivers // [] | join(" ") | if . == "" then "-" else . end)",
    row("source"; "spans"),
    row("Collector receivers accepted"; .collector.receiver_accepted.count | n),
    row("Collector receivers refused"; .collector.receiver_refused.count | n),
    row("Collector receivers failed"; .collector.receiver_failed.count | n),
    row("exporter otlp_grpc/tempo sent"; "\(.collector.exporter_sent.count | n) (\(.collector.exporter_sent_per_second | n) span/s)"),
    row("exporter otlp_grpc/tempo send failed"; .collector.exporter_send_failed.count | n),
    row("exporter otlp_grpc/tempo not queued"; .collector.exporter_enqueue_failed.count | n),
    row("Tempo received (since its start)"; .tempo.spans_received | n),
    row("Tempo discarded (since its start)"; "\(.tempo.discarded_total | n)\((.tempo.discarded // {}) | if . == {} then "" else " (" + (to_entries | map("\(.key) \(.value)") | join(", ")) + ")" end)"),
    row("Tempo live traces (now)"; .tempo.live_traces | n),
    "  container tempo: restartCount \(.tempo.container.restart_count | n), started \(.tempo.container.started_at | n)",
    "  search: \(.read.traces_in_window | n) trace(s) of gateway in the window; trace \(.read.trace.id | n): \(.read.trace.services // {} | to_entries | map("\(.key) \(.value)") | join(", "))",
    "  service graph gateway -> feed-service: \(.collector.service_graph_gateway_feed.count | n) request(s) over the window",
    (.mode as $m | .reasons[] | "  \(if $m == "record" then "note" else "FAIL" end)  \(.)")
  ' "$1"
}

# tempo_check LABEL: the check (see the header); returns 0 when LABEL passed.
tempo_check() {
  local label=$1 mode line from to secs file c t r p
  case $label in
    k6-pods-8) mode=record ;;
    k6-pods-1 | k6-pods-2 | k6-pods-4 | chaos-[a-z]) mode=strict ;;
    *)
      echo "FAIL  verify-tempo: no criteria for label '$label' (k6-pods-1, -2, -4, -8, chaos-<x>)" >&2
      return 2
      ;;
  esac
  line=$(awk -F '\t' -v l="$label" '$1 == l { last = $2 " " $3 } END { print last }' \
    "$SVP_VERIFY_OUT/k6-windows.tsv" 2>/dev/null)
  read -r from to <<<"$line"
  case "$from$to" in '' | *[!0-9]*)
    echo "FAIL  verify-tempo: no hold window for $label in k6-windows.tsv"
    return 1
    ;;
  esac
  secs=$((to - from))
  [ "$secs" -gt 0 ] || {
    echo "FAIL  verify-tempo: the hold window of $label is empty ($from to $to)"
    return 1
  }
  for p in $prom_port $tempo_port; do
    port_free "$p" || {
      echo "FAIL  verify-tempo: 127.0.0.1:$p is in use (another port-forward?); free it and run again"
      return 1
    }
  done
  trap stop_forwards EXIT
  trap 'stop_forwards; exit 130' INT TERM
  forward service/kps-prometheus "$prom_port:9090"
  forward pod/tempo-0 "$tempo_port:3200"
  if ready "http://127.0.0.1:$prom_port/-/ready"; then c=$(collector); else c='{"answered": false}'; fi
  # The container is read either way: a Tempo that does not answer is often one that restarts.
  t=$(tempo_side)
  if ready "http://127.0.0.1:$tempo_port/ready"; then r=$(read_back); else r='{"search_answered": false}'; fi
  stop_forwards
  mkdir -p "$repo/.k8s/drills"
  file=$repo/.k8s/drills/tempo-ingest-$label-$(date -u +%Y%m%dT%H%M%SZ).json
  jq -n --arg label "$label" --argjson from "$from" --argjson to "$to" --argjson c "$c" --argjson t "$t" --argjson r "$r" \
    '{label: $label, window: {from: $from, to: $to, seconds: ($to - $from)}, collector: $c, tempo: $t, read: $r}' |
    verdict "$mode" >"$file" || {
    echo "FAIL  verify-tempo: the results of $label were not written"
    return 1
  }
  report "$file"
  echo "results in ${file#"$repo"/}"
  [ "$(jq -r .result "$file")" = pass ]
}

# tempo_test: the self-test (see the header). Each case runs tempo_check in a subshell over the fixtures of a clean
# window, one fixture changed.
tempo_test() {
  local work bin failures=0 from=1798000000 to=1798000600 pid
  work=$(mktemp -d)
  # Expanded now: work is local, gone when the trap runs at the script's exit.
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  bin=$work/bin
  mkdir -p "$bin" "$work/repo" "$work/out"
  export SVP_VERIFY_OUT=$work/out FAKE_DIR=$work
  repo=$work/repo
  forward_wait_s=1
  ok() { echo "ok    $1"; }
  fail() {
    echo "FAIL  $1" >&2
    failures=$((failures + 1))
  }
  same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
  # nc -z: 0 (taken) only for the port in FAKE_PORT_TAKEN.
  cat >"$bin/nc" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do last=$a; done
[ "$last" = "${FAKE_PORT_TAKEN:-}" ]
EOS
  # kubectl: a port-forward is a sleep killed by its pid (recorded in forwards, to check none is left); get pod prints
  # pod.json.
  cat >"$bin/kubectl" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *" port-forward "*) echo $$ >>"$FAKE_DIR/forwards"; exec sleep 300 ;;
  *" get pod tempo-0 -o json"*) [ -z "${FAKE_POD_FAIL:-}" ] && cat "$FAKE_DIR/pod.json" ;;
  *) exit 1 ;;
esac
EOS
  # curl: Prometheus answers each query from prom.json ({metric: {inc, max, start}}: the value of sum(increase()),
  # sum(max_over_time()) and sum() at the window's start; a metric or value missing has no series); Tempo answers
  # /metrics, /api/search and /api/traces/<id> from tempo-metrics.txt, search.json and trace-<id>.json.
  cat >"$bin/curl" <<'EOS'
#!/usr/bin/env bash
url= q=
while [ $# -gt 0 ]; do
  case $1 in
    http://*) url=$1 ;;
    --data-urlencode) shift; case $1 in query=*) q=${1#query=} ;; esac ;;
  esac
  shift
done
case $url in
  http://127.0.0.1:19090/*) [ -z "${FAKE_PROM_DOWN:-}" ] || exit 7 ;;
  http://127.0.0.1:13200/*) [ -z "${FAKE_TEMPO_DOWN:-}" ] || exit 7 ;;
esac
case $url in
  */-/ready | */ready) ;;
  */api/v1/query)
    name=$(printf '%s' "$q" | grep -oE '(otelcol|traces)_[a-z_]+' | head -n 1)
    case $q in
      "count by"*) kind=receivers ;;
      "sum(increase("*) kind=inc ;;
      "sum(max_over_time("*) kind=max ;;
      *) kind=start ;;
    esac
    jq -c --arg n "$name" --arg k "$kind" '(if $k == "receivers" then (if .[$n] then [{metric: {receiver: "otlp", transport: "grpc"}, value: [0, "1"]}] else [] end)
      else (.[$n][$k] // null | if . == null then [] else [{metric: {}, value: [0, tostring]}] end) end)
      | {status: "success", data: {resultType: "vector", result: .}}' "$FAKE_DIR/prom.json"
    ;;
  */metrics) cat "$FAKE_DIR/tempo-metrics.txt" ;;
  */api/search) [ -f "$FAKE_DIR/search.json" ] || exit 22; cat "$FAKE_DIR/search.json" ;;
  */api/traces/*) f=$FAKE_DIR/trace-${url##*/}.json; [ -f "$f" ] || exit 22; cat "$f" ;;
  *) exit 7 ;;
esac
EOS
  chmod +x "$bin"/*
  PATH=$bin:$PATH
  # trace ID SERVICE:SPANS...: trace-ID.json, in the shape of /api/traces/<id> of Tempo 3.1.0 (OTLP under batches).
  trace() {
    local id=$1 s
    shift
    for s in "$@"; do
      jq -nc --arg s "${s%%:*}" --argjson n "${s#*:}" '{resource: {attributes: [{key: "service.name", value:
        {stringValue: $s}}]}, scopeSpans: [{spans: [range(0; $n) | {name: "op", attributes: [{key: "http.route",
        value: {stringValue: "/feed/explore"}}]}]}]}'
    done | jq -s '{batches: .}' >"$work/trace-$id.json"
  }
  clean() {
    rm -f "$work"/trace-*.json "$work/forwards"
    rm -rf "$work/repo/.k8s"
    printf 'chaos-a\t%s\t%s\t1\nk6-pods-4\t%s\t%s\t4\nk6-pods-8\t%s\t%s\t8\n' "$from" "$to" "$from" "$to" "$from" "$to" \
      >"$SVP_VERIFY_OUT/k6-windows.tsv"
    jq -n '{
      otelcol_receiver_accepted_spans_total: {inc: 720000, max: 1720000, start: 1000000},
      otelcol_receiver_refused_spans_total: {inc: 0, max: 0, start: 0},
      otelcol_receiver_failed_spans_total: {inc: 0, max: 0, start: 0},
      otelcol_exporter_sent_spans_total: {inc: 720000, max: 1720000, start: 1000000},
      traces_service_graph_request_total: {inc: 30000, max: 50000, start: 20000}}' >"$work/prom.json"
    printf '%s\n' '# HELP tempo_distributor_spans_received_total The total number of spans received per tenant' \
      'tempo_distributor_spans_received_total{tenant="single-tenant"} 1.72e+06' \
      'tempo_live_store_live_traces{tenant="single-tenant"} 4211' >"$work/tempo-metrics.txt"
    jq -n '{items: [], status: {containerStatuses: [{name: "tempo", restartCount: 0,
      state: {running: {startedAt: "2026-12-01T00:00:00Z"}}, lastState: {}}]}}' >"$work/pod.json"
    # Three traces of gateway: one started before the window, one of gateway alone, one through feed-service.
    jq -n --argjson f "$from" '{traces: [
      {traceID: "0a", rootServiceName: "gateway", startTimeUnixNano: ("\($f - 60)000000000")},
      {traceID: "0b", rootServiceName: "gateway", startTimeUnixNano: ("\($f + 10)000000000")},
      {traceID: "0c", rootServiceName: "gateway", startTimeUnixNano: ("\($f + 20)000000000")}]}' >"$work/search.json"
    trace 0a gateway:2 feed-service:1
    trace 0b gateway:1
    trace 0c gateway:3 feed-service:2 engagement-service:1
  }
  # prom_set JQ: edits prom.json.
  prom_set() { jq "$1" "$work/prom.json" >"$work/edit" && mv "$work/edit" "$work/prom.json"; }
  # run LABEL: tempo_check LABEL in a subshell; prints "rc result reasons" (reasons joined by "; ").
  run() {
    local rc f
    (tempo_check "$1") >"$work/out.txt" 2>&1
    rc=$?
    f=$(ls "$work/repo/.k8s/drills/tempo-ingest-$1-"*.json 2>/dev/null | head -n 1)
    if [ -n "$f" ]; then
      echo "$rc $(jq -r '"\(.result) \(.reasons | join("; "))"' "$f")"
    else
      echo "$rc no-file $(tr '\n' ' ' <"$work/out.txt")"
    fi
  }

  clean
  same "clean: passes, every source measured" "0 pass " "$(run chaos-a)"
  f=$(ls "$work/repo/.k8s/drills"/tempo-ingest-chaos-a-*.json)
  same "clean: the window's numbers" "otlp/grpc 720000 0 0 720000 1200 0 0 1720000 0 4211 0c 3 30000" \
    "$(jq -r '[(.collector.receivers | join(",")), .collector.receiver_accepted.count, .collector.receiver_refused.count,
      .collector.receiver_failed.count, .collector.exporter_sent.count, .collector.exporter_sent_per_second,
      .collector.exporter_send_failed.count, .collector.exporter_enqueue_failed.count, .tempo.spans_received,
      .tempo.discarded_total, .tempo.live_traces, .read.trace.id, (.read.trace.services | length),
      .collector.service_graph_gateway_feed.count] | map(tostring) | join(" ")' "$f")"
  same "clean: the JSON holds no span attribute" 0 "$(jq '[paths | .[-1] | select(. == "attributes")] | length' "$f")"
  grep -q '^tempo-ingest chaos-a: PASS (strict)' "$work/out.txt" && grep -q 'exporter otlp_grpc/tempo sent  *720000 (1200 span/s)$' "$work/out.txt" &&
    ok "clean: the table" || fail "clean: the table: $(cat "$work/out.txt")"
  for pid in $(cat "$work/forwards"); do
    ! kill -0 "$pid" 2>/dev/null || fail "clean: port-forward $pid still runs after the check"
  done
  same "clean: two port-forwards, both stopped" 2 "$(grep -c . "$work/forwards")"

  clean
  printf '%s\n' 'tempo_discarded_spans_total{reason="rate_limited",tenant="single-tenant"} 120' \
    'tempo_discarded_spans_total{reason="live_traces_exceeded",tenant="single-tenant"} 3' >>"$work/tempo-metrics.txt"
  case $(run k6-pods-4) in
    "1 fail Tempo discarded 123 span(s) in the run ("*"rate_limited 120"*) ok "discarded: Tempo dropping spans fails, by reason" ;;
    *) fail "discarded: got '$(run k6-pods-4)'" ;;
  esac
  clean
  # Born inside the window: increase() reads nothing of its first value, the highest value minus none at the start does.
  prom_set '.otelcol_exporter_enqueue_failed_spans_total = {inc: 0, max: 512}'
  same "dropped: spans the exporter could not queue (a series born in the window) fail" \
    "1 fail exporter otlp_grpc/tempo lost 512 span(s) (send failed 0, not queued 512)" "$(run k6-pods-4)"
  clean
  prom_set '.otelcol_exporter_send_failed_spans_total = {inc: 40, max: 90, start: 50}'
  same "dropped: send failures grown in the window fail; those before it do not count" \
    "1 fail exporter otlp_grpc/tempo lost 40 span(s) (send failed 40, not queued 0)" "$(run chaos-a)"
  clean
  prom_set '.otelcol_receiver_refused_spans_total = {inc: 2048, max: 2048, start: 0}'
  same "refused: the exporter without a failure but the receivers refusing spans fails" \
    "1 fail the Collector refused 2048 span(s) at its receivers (refused 2048, failed 0)" "$(run chaos-a)"

  clean
  jq '.traces = []' "$work/search.json" >"$work/edit" && mv "$work/edit" "$work/search.json"
  same "no trace: no trace of gateway in the window fails" "1 fail no trace with a span of gateway started in the window" \
    "$(run chaos-a)"
  clean
  jq --argjson f "$from" '.traces = [.traces[] | select(.traceID != "0c")]' "$work/search.json" >"$work/edit" &&
    mv "$work/edit" "$work/search.json"
  same "no trace: a trace of gateway alone fails" "1 fail no trace fetched holds spans of 2 services (gateway)" "$(run chaos-a)"
  clean
  prom_set '.traces_service_graph_request_total = {inc: 0, max: 50000, start: 50000}'
  same "service graph: no gateway -> feed-service request grown fails" \
    "1 fail no gateway -> feed-service request grew in the service graph over the window" "$(run chaos-a)"

  clean
  prom_set 'del(.otelcol_receiver_refused_spans_total)'
  same "unmeasured: no series of the receivers' refusals fails, never read as 0" \
    "1 fail unmeasured: no series otelcol_receiver_refused_spans_total" "$(run chaos-a)"
  clean
  same "unmeasured: Prometheus not answering fails" "1 fail unmeasured: Prometheus did not answer" \
    "$(FAKE_PROM_DOWN=1 run chaos-a)"
  clean
  same "unmeasured: Tempo not answering fails, its search too" \
    "1 fail unmeasured: Tempo /metrics did not answer; unmeasured: Tempo search did not answer" \
    "$(FAKE_TEMPO_DOWN=1 run chaos-a)"
  clean
  jq '.status.containerStatuses[0].restartCount = 3 | .status.containerStatuses[0].lastState = {terminated: {reason: "OOMKilled"}}' \
    "$work/pod.json" >"$work/edit" && mv "$work/edit" "$work/pod.json"
  same "restart: Tempo restarted in the run fails, its zero discards not trusted" \
    "1 fail Tempo counters do not cover the window: container tempo restartCount 3, started 2026-12-01T00:00:00Z, last ended OOMKilled" \
    "$(run chaos-a)"
  clean
  jq --arg s "$(jq -nr --argjson t "$((from + 60))" '$t | todate')" '.status.containerStatuses[0].state.running.startedAt = $s' \
    "$work/pod.json" >"$work/edit" && mv "$work/edit" "$work/pod.json"
  case $(run chaos-a) in
    "1 fail Tempo counters do not cover the window: container tempo restartCount 0, started "*) ok "restart: Tempo started inside the window fails" ;;
    *) fail "restart: Tempo started inside the window: got '$(run chaos-a)'" ;;
  esac

  clean
  printf '%s\n' 'tempo_discarded_spans_total{reason="rate_limited",tenant="single-tenant"} 90000' >>"$work/tempo-metrics.txt"
  prom_set '.otelcol_receiver_refused_spans_total = {inc: 5000, max: 5000, start: 0}'
  same "8 pods: spans dropped are recorded, the level passes" \
    "0 pass the Collector refused 5000 span(s) at its receivers (refused 5000, failed 0); Tempo discarded 90000 span(s) in the run (rate_limited 90000)" \
    "$(run k6-pods-8)"
  grep -q '^  note  ' "$work/out.txt" && ok "8 pods: the reasons are notes in the table" || fail "8 pods: notes: $(cat "$work/out.txt")"

  clean
  same "port taken: stops with the port named, nothing written" \
    "1 no-file FAIL  verify-tempo: 127.0.0.1:13200 is in use (another port-forward?); free it and run again " \
    "$(FAKE_PORT_TAKEN=13200 run chaos-a)"
  [ ! -e "$work/forwards" ] && ok "port taken: no port-forward started" || fail "port taken: a port-forward started"
  clean
  same "no window: a label without a line in k6-windows.tsv fails" \
    "1 no-file FAIL  verify-tempo: no hold window for chaos-b in k6-windows.tsv " "$(run chaos-b)"
  same "label: one without criteria stops the script" "2 no-file FAIL  verify-tempo: no criteria for label 'k6-pods-3' (k6-pods-1, -2, -4, -8, chaos-<x>) " \
    "$(run k6-pods-3)"

  echo "tempo_test: $failures failure(s)"
  [ "$failures" = 0 ]
}

case ${1:-} in
  test) tempo_test ;;
  '' | -*)
    echo "usage: verify-tempo.sh LABEL | test" >&2
    exit 2
    ;;
  *)
    # ci_temp_dir: the default results folder, as deploy/ci/verify-run.sh's.
    # shellcheck source=deploy/ci/platform.sh
    . "$here/platform.sh"
    if [ -z "${SVP_VERIFY_OUT:-}" ]; then
      SVP_VERIFY_OUT=$(ci_temp_dir)/verify || exit 1
    fi
    tempo_check "$1"
    ;;
esac
