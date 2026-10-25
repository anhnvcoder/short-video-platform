#!/usr/bin/env bash
# Disaster recovery drill of Postgres svp-pg in place, on the dev cluster svp: the database is deleted with its volume
# and created again under the same name from its backups in bucket
# pg-backups (Barman Cloud plugin), and the drill measures how long the platform is down (RTO) and how much committed
# work is lost (RPO).
#
#   1. Database svp_drill, table markers (id, run, written_at), made when missing: no service table is written. Every
#      row of this run carries its run id, so a second run on the same cluster reads only its own.
#   2. A Backup on demand (method plugin) of the running archive generation, waited for until completed, and WAL
#      archiving working (condition ContinuousArchiving True). Either missing: the drill stops before deleting anything.
#   3. One marker a second for 60 s, written_at by Postgres' clock. MODE=latest (default) forces no WAL switch: the
#      restore ends wherever the archive ends. MODE=pitr picks a target time 0.5 s after marker 30 (marker 31 comes at
#      least 1 s after it), forces pg_switch_wal() and waits until that segment is archived. Then, just before the
#      deletion: last_archived_wal and last_archived_time of pg_stat_archiver, the row count of every table of the four
#      services' databases (SELECT count only), WAL archiving checked again (it may have broken while the markers were
#      written: condition ContinuousArchiving True and no failure in pg_stat_archiver after its last success, or the
#      drill stops there, before deleting anything), and the deletion time by Postgres' clock.
#   4. Cluster svp-pg deleted the ordinary way (its pod shuts down cleanly, so CloudNativePG may archive what it can on
#      the way out), and its PersistentVolumeClaims with it. No Backup, no object of the bucket is ever deleted.
#   5. T0: chart svp-data upgraded with postgres.recovery.source = the old generation and postgres.backup.serverName = a
#      new one, svp-pg-<yymmddhhmmss> (UTC; MODE=pitr adds postgres.recovery.targetTime): Cluster svp-pg is created
#      again, same name, so Service svp-pg-rw and every service's Secret stay as they are, restored by bootstrap.recovery
#      and archiving into the new, empty generation. These values are on that one command line only; make k8s-up later
#      keeps the new generation (deploy/k8s/install.sh reads it from the Cluster) and drops bootstrap, which
#      CloudNativePG reads only when it creates the first instance.
#   6. Once the Cluster is Ready, the row counts again, then one restart of the Deployments of the four services with
#      Postgres and of GlitchTip: they have been in CrashLoopBackOff, whose back-off (up to 5 minutes) would make the RTO
#      random. The JSON says they were restarted.
#   7. T1: the end-to-end smoke test of make k8s-smoke passes through Envoy. RTO = T1 - T0.
#   8. RPO = deletion time - written_at of the newest marker of this run that came back; the markers lost are counted.
#      When none came back, the restore ended before the first marker committed, so everything after that was lost:
#      RPO is at least deletion time - written_at of the first marker (read before the deletion, about the 60 s of
#      markers), printed and written to the JSON as a lower bound (rpo.at_least true).
#      MODE=pitr passes when the newest marker back is at or before the target and less than 1 s before it.
#   9. A Backup of the new generation, so that it has a recovery point at once (the restore's upgrade makes
#      ScheduledBackup svp-pg-daily again, which takes no second immediate Backup), and WAL archiving working there.
#
# Each step prints ok or FAIL; the run ends with one JSON in .k8s/drills/backup-<time>.json: the times of each step,
# RTO, RPO, the generations, the backups, the forced WAL switch, the last archived segment and its time, the markers
# written, kept and lost, the row counts before and after and the workloads restarted. Two runs in a row on one cluster
# (MODE=latest, then MODE=pitr) both pass: each restores from the generation the one before made.
#
# Stopped half way (Ctrl-C, a failure), the drill prints what state the database is in and the commands that finish
# the restore by hand (docs/runbooks/postgres-restore.md has them too). make k8s-up refuses to run while svp-pg is
# missing and Backups of it remain, so it cannot create an empty database over it, and while svp-pg is still being
# restored, so it cannot take bootstrap.recovery away from the restore.
#
# Dev path only: on the GitOps cluster Argo CD would set the generation back to the one in git. LOCAL LAB ONLY: only
# the k3d context k3d-svp whose API server is this machine's 127.0.0.1:6550, checked before anything else runs; like
# make k8s-smoke it then deletes the register rate limit keys svp:gw:rl:register:* in the cluster's Valkey db 10
# (deploy/compose/lib.sh, as it is sourced). Usage (from the repo root, cluster up): make drill-k8s-backup
# [MODE=latest|pitr].
set -euo pipefail

base=${1:-https://api.svp.localhost:8443}
mode=${MODE:-latest}
case $mode in
  latest | pitr) ;;
  *)
    echo "FAIL  MODE must be latest or pitr (got '$mode')" >&2
    exit 1
    ;;
esac

# kubectl, docker and fail for the checks below; deploy/k8s/lib.sh only defines things.
# shellcheck source=deploy/k8s/lib.sh
source "$(dirname "$0")/../lib.sh"

# --- Checks before anything changes ---------------------------------------------------------------------------------

# Before drills/lib.sh, which deletes the register rate limit keys in the cluster's Valkey as it is sourced: kc names
# the context; the context must also be the cluster of this machine, created by make k8s-up (k3d.yaml publishes its API
# on 127.0.0.1:6550 only), never one that a kubeconfig entry of the same name points elsewhere.
server=$(kubectl config view --minify --context k3d-svp -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) ||
  server=
case $server in
  https://127.0.0.1:6550 | https://localhost:6550 | https://0.0.0.0:6550) ;;
  *) fail "context k3d-svp points at '$server', not the local cluster's https://127.0.0.1:6550; LOCAL LAB ONLY" ;;
esac
[[ $(docker_ inspect --format '{{.State.Running}}' k3d-svp-server-0 2>/dev/null) == true ]] ||
  fail "node container k3d-svp-server-0 is not running on this machine; LOCAL LAB ONLY"
if kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1; then
  fail "cluster svp is managed by Argo CD (GitOps path), which would set the archive generation back to git's: this drill is for the dev path (make k8s-up) only"
fi

# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

ns=svp-data
chart="$repo_root/deploy/helm/svp-data"
plugin=barman-cloud.cloudnative-pg.io
drills="$repo_root/.k8s/drills"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
run=$stamp
mkdir -p "$drills"
service_dbs="svp_user svp_video svp_engagement svp_feed"

# What has been done so far, for the message of an interrupted run (drill_exit): prepare (nothing deleted), deleting,
# restoring (the upgrade that creates svp-pg again has been started), restored (svp-pg is Ready again), done.
phase=prepare
old_gen= new_gen= target= restore_cmd=
drill_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" != 0 ] && [ "$phase" != done ]; then
    way_back >&2
  fi
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT
trap 'exit 130' INT TERM

# way_back: the state the drill leaves svp-pg in and the commands that finish the restore by hand.
way_back() {
  echo "note  the drill stopped during step '$phase'; no Backup and no object of bucket pg-backups was deleted"
  case $phase in
    prepare)
      echo "note  nothing was deleted: Cluster svp-data/svp-pg runs as before (archive generation ${old_gen:-unchanged})"
      ;;
    deleting | restoring)
      echo "note  Cluster svp-pg may be gone or still restoring. Do not run make k8s-up before it is Ready: with no Cluster it"
      echo "      would create an empty database, and it would drop bootstrap.recovery from a Cluster still restoring (it refuses"
      echo "      both). Finish the restore from generation $old_gen into $new_gen, from the repo root:"
      echo "      kubectl --context k3d-svp -n svp-data get cluster svp-pg   # NotFound: run the next line; found: skip it"
      echo "      $restore_cmd"
      echo "      kubectl --context k3d-svp -n svp-data wait --for=condition=Ready cluster/svp-pg --timeout=900s"
      way_after_ready
      ;;
    restored)
      echo "note  Cluster svp-pg is back (generation $new_gen); what is left, from the repo root:"
      way_after_ready
      ;;
  esac
  echo "note  each step with its checks: docs/runbooks/postgres-restore.md"
}
way_after_ready() {
  echo "      kubectl --context k3d-svp -n svp rollout restart deployment user-service video-service engagement-service feed-service"
  echo "      kubectl --context k3d-svp -n svp-obs rollout restart deployment glitchtip"
  echo "      make k8s-smoke"
  echo "      make k8s-up   # keeps generation $new_gen, removes bootstrap.recovery, takes a base backup of $new_gen when it has none"
}

cluster_field() { kc -n "$ns" get clusters.postgresql.cnpg.io svp-pg -o jsonpath="$1"; }
condition() { cluster_field "{.status.conditions[?(@.type==\"$1\")].status}" 2>/dev/null; }

kc -n "$ns" get clusters.postgresql.cnpg.io svp-pg >/dev/null 2>&1 ||
  fail "Cluster svp-data/svp-pg not found (nothing to restore from; a drill stopped half way? see docs/runbooks/postgres-restore.md)"
old_gen=$(cluster_field "{.spec.plugins[?(@.name==\"$plugin\")].parameters.serverName}") ||
  fail "read Cluster svp-data/svp-pg"
[[ -n $old_gen ]] || fail "Cluster svp-pg has no Barman Cloud plugin with a serverName: run make k8s-up first"
[[ $(condition Ready) == True ]] || fail "Cluster svp-pg is not Ready ($(cluster_field '{.status.phase}'))"
kc -n "$ns" get objectstores.barmancloud.cnpg.io svp-pg-backup >/dev/null ||
  fail "ObjectStore svp-data/svp-pg-backup not found: run make k8s-up first"
kc -n cnpg-system wait --for=condition=Available deployment/plugin-barman-cloud --timeout=60s >/dev/null ||
  fail "Barman Cloud plugin (cnpg-system/plugin-barman-cloud) available"
new_gen=svp-pg-$(date -u +%y%m%d%H%M%S)
[[ $new_gen != "$old_gen" ]] || fail "new generation name $new_gen equals the running one; run again in a second"
ok "Cluster svp-pg Ready, archiving into generation $old_gen; the restore will archive into $new_gen (MODE=$mode)"

primary() { cluster_field '{.status.currentPrimary}'; }
# psql DB ARGS...: psql as postgres inside the primary's postgres container (peer login on the pod's socket, as the
# image's postgres user), unaligned, tuples only, stopping at the first error. SQL on stdin with -i.
psql_() {
  local db=$1 pod
  shift
  pod=$(primary) && [[ -n $pod ]] || fail "read the primary of Cluster svp-pg"
  kc -n "$ns" exec -i "$pod" -c postgres -- psql -X -q -A -t -v ON_ERROR_STOP=1 -U postgres -d "$db" "$@"
}

# row_counts FILE: "<database>.<schema>.<table><TAB><rows>" of every table of the services' databases, sorted. Each
# count is a SELECT generated from pg_stat_user_tables and run by \gexec.
row_counts() {
  local db
  : >"$1"
  for db in $service_dbs; do
    printf '%s\n' "select format('select %L, count(*) from %I.%I', '$db.' || schemaname || '.' || relname, schemaname, relname) from pg_stat_user_tables order by schemaname, relname \gexec" |
      psql_ "$db" -F $'\t' >>"$1" || fail "count the rows of the tables of $db"
  done
  LC_ALL=C sort -o "$1" "$1"
}
counts_json() { jq -Rn '[inputs | select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries' <"$1"; }

# The drill's Backups are made by pg_backup (deploy/k8s/lib.sh): owned by nothing, so that deleting the Cluster leaves
# them, and waited for until completed; their times are read from their status.
backup_field() { kc -n "$ns" get backups.postgresql.cnpg.io "$1" -o jsonpath="$2"; }

declare_time() { printf -v "t_$1" '%s' "$(now)"; }
declare_time start

# --- 1. Drill table ---------------------------------------------------------------------------------------------------

if [[ -z $(psql_ postgres -c "select 1 from pg_database where datname = 'svp_drill'") ]]; then
  psql_ postgres -c 'create database svp_drill' >/dev/null || fail "create database svp_drill"
fi
psql_ svp_drill -c 'create table if not exists markers (
    id bigserial primary key, run text not null, written_at timestamptz not null default clock_timestamp())' \
  >/dev/null || fail "create table svp_drill.markers"
ok "database svp_drill, table markers ready (run $run)"

# --- 2. Base backup and WAL archiving ---------------------------------------------------------------------------------

base_backup=svp-pg-drill-$(date -u +%Y%m%d%H%M%S)
pg_backup "$base_backup"
declare_time base_backup
[[ $(condition ContinuousArchiving) == True ]] ||
  fail "Cluster svp-pg archives WAL (condition ContinuousArchiving is '$(condition ContinuousArchiving)'); nothing was deleted"
ok "Backup $base_backup completed ($(backup_field "$base_backup" '{.status.startedAt} - {.status.stoppedAt}')), WAL archiving on"

# --- 3. Markers -------------------------------------------------------------------------------------------------------

# One transaction per marker, a second apart, inside the server: written_at is Postgres' clock, and no round trip of
# kubectl exec stretches the spacing.
psql_ svp_drill -c "do \$\$ begin for i in 1..60 loop insert into markers (run) values ('$run'); commit; perform pg_sleep(1); end loop; end \$\$" \
  >/dev/null || fail "write the markers"
declare_time markers
written=$(psql_ svp_drill -c "select count(*) from markers where run = '$run'")
[[ $written == 60 ]] || fail "60 markers written (got $written)"
# Read now: the RPO's lower bound when no marker comes back from the restore.
first_marker=$(psql_ svp_drill -c "select to_char(min(written_at) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
    from markers where run = '$run'")
[[ $first_marker =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]] ||
  fail "read the time of the first marker (got '$first_marker')"
ok "60 markers written, one a second"

forced=false
if [[ $mode == pitr ]]; then
  # 0.5 s after marker 30, whatever the node's pace: its commit follows its insert by milliseconds, and marker 31 is
  # written at least 1 s after it (pg_sleep(1) between them). So the newest marker a recovery to this time keeps is
  # marker 30, 0.5 s before it: within the 1 s step 8 allows, where halfway to marker 31 would not be on a slow node.
  target=$(psql_ svp_drill -c "select to_char((written_at + interval '0.5 second') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
      from markers where run = '$run' order by id offset 29 limit 1")
  [[ $target =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]] ||
    fail "pick the target time 0.5 s after marker 30 (got '$target')"
  segment=$(psql_ postgres -c 'select pg_walfile_name(pg_switch_wal())') || fail "pg_switch_wal()"
  forced=true
  # WAL segment names are 24 hex digits (timeline, log, segment), so a newer one sorts after an older one; a backup
  # label or timeline history file (other names) the archiver may report is not a segment and is waited past.
  deadline=$((SECONDS + 300))
  until archived=$(psql_ postgres -c "select coalesce(last_archived_wal, '') from pg_stat_archiver") &&
    [[ $archived =~ ^[0-9A-F]{24}$ ]] && ! [[ $archived < $segment ]]; do
    ((SECONDS < deadline)) || fail "WAL segment $segment archived within 300s (last archived '$archived'); nothing was deleted"
    sleep 2
  done
  ok "target time $target (0.5 s after marker 30); WAL switched, segment $segment archived"
fi

read -r last_wal last_wal_time <<<"$(psql_ postgres -F ' ' -c "select coalesce(last_archived_wal, '-'),
    coalesce(to_char(last_archived_time at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), '-') from pg_stat_archiver")"
row_counts "$work/counts-before"
# WAL archiving again, a minute after step 2: MinIO or the sidecar may have failed while the markers were written, and
# the deletion would then lose what was never archived. pg_stat_archiver shows a failure as soon as the archiver meets
# one, the condition once CloudNativePG has recorded it.
[[ $(condition ContinuousArchiving) == True ]] ||
  fail "Cluster svp-pg archives WAL just before the deletion (condition ContinuousArchiving is '$(condition ContinuousArchiving)'); nothing was deleted"
[[ $(psql_ postgres -c "select last_failed_time is not null and (last_archived_time is null or last_failed_time > last_archived_time) from pg_stat_archiver") == f ]] ||
  fail "pg_stat_archiver shows a WAL archiving failure after its last success, just before the deletion (docs/runbooks/postgres-wal-archiving-failing.md); nothing was deleted"
deleted_at=$(psql_ postgres -c "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")
ok "before the deletion: last archived WAL $last_wal at $last_wal_time, $(wc -l <"$work/counts-before" | tr -d ' ') service tables counted, deletion at $deleted_at (Postgres' clock)"

# --- 4. Delete the database -------------------------------------------------------------------------------------------

restore_cmd="helm --kube-context k3d-svp upgrade svp-data deploy/helm/svp-data --namespace svp-data --set-string postgres.backup.serverName=$new_gen --set-string postgres.recovery.source=$old_gen${target:+ --set-string postgres.recovery.targetTime=$target} --set initJobs.waitSeconds=900 --wait=hookOnly --timeout 20m"
phase=deleting
declare_time delete
kc -n "$ns" delete clusters.postgresql.cnpg.io svp-pg --wait=true --timeout=300s >/dev/null ||
  fail "delete Cluster svp-pg within 300s"
# The PersistentVolumeClaims belong to the Cluster and are garbage collected after it; any left are deleted here.
pvcs() { kc -n "$ns" get pvc -l cnpg.io/cluster=svp-pg -o name; }
deadline=$((SECONDS + 120))
while [[ -n $(pvcs) ]] && ((SECONDS < deadline)); do sleep 2; done
if [[ -n $(pvcs) ]]; then
  kc -n "$ns" delete pvc -l cnpg.io/cluster=svp-pg --wait=true --timeout=120s >/dev/null || fail "delete the PVCs of svp-pg"
fi
[[ -z $(pvcs) ]] || fail "PVCs of svp-pg deleted"
declare_time deleted
ok "Cluster svp-pg and its PVCs deleted (Backups and bucket untouched)"

# --- 5. Restore under the same name (T0) ------------------------------------------------------------------------------

phase=restoring
declare_time t0
restore=(upgrade svp-data "$chart" --namespace "$ns"
  --set-string "postgres.backup.serverName=$new_gen" --set-string "postgres.recovery.source=$old_gen")
[[ -z $target ]] || restore+=(--set-string "postgres.recovery.targetTime=$target")
# The init Jobs are hooks of this release; pg-bootstrap waits for the server, which comes up only once the base backup
# and the WAL are restored: up to 900 s instead of the usual 300 s. --wait=hookOnly: the Cluster's readiness is waited
# for below, with the operator's own condition.
restore+=(--set initJobs.waitSeconds=900 --wait=hookOnly --timeout 20m)
echo "      $restore_cmd"
hc "${restore[@]}" >/dev/null || fail "upgrade svp-data to restore svp-pg"
if ! kc -n "$ns" wait --for=condition=Ready clusters.postgresql.cnpg.io/svp-pg --timeout=900s >/dev/null; then
  echo "      phase $(cluster_field '{.status.phase}' 2>/dev/null || true): $(cluster_field '{.status.phaseReason}' 2>/dev/null || true)" >&2
  echo "      recovery Job log: kubectl --context k3d-svp -n svp-data logs -l cnpg.io/cluster=svp-pg,cnpg.io/jobRole=full-recovery --all-containers --tail=100" >&2
  fail "Cluster svp-pg Ready within 900s of the restore"
fi
phase=restored
declare_time ready
got=$(cluster_field "{.spec.plugins[?(@.name==\"$plugin\")].parameters.serverName}")
[[ $got == "$new_gen" ]] || fail "restored Cluster archives into generation $new_gen (got '$got')"
ok "Cluster svp-pg restored from generation $old_gen and Ready, archiving into $new_gen"

row_counts "$work/counts-after"
read -r kept last_kept rpo lost_after_target <<<"$(psql_ svp_drill -F ' ' -c "select count(*),
    coalesce(to_char(max(written_at) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), '-'),
    coalesce(round(extract(epoch from timestamptz '$deleted_at' - max(written_at))::numeric, 3)::text, '-'),
    count(*) filter (where written_at > timestamptz '${target:-infinity}')
    from markers where run = '$run'")"
[[ $kept =~ ^[0-9]+$ && $lost_after_target =~ ^[0-9]+$ ]] || fail "read the markers of run $run back from svp_drill"

# --- 6. Restart what crash-looped -------------------------------------------------------------------------------------

restarted=()
for svc in user-service video-service engagement-service feed-service; do
  restart_workload svp "$svc"
  restarted+=("svp/$svc")
done
restart_workload svp-obs glitchtip
restarted+=(svp-obs/glitchtip)
declare_time restarted
ok "restarted once: ${restarted[*]}"

# --- 7. Smoke test (T1) -----------------------------------------------------------------------------------------------

"$repo_root/deploy/compose/smoke.sh" "$base" || fail "end-to-end smoke test after the restore"
declare_time t1
rto=$(awk -v a="$t_t0" -v b="$t_t1" 'BEGIN { printf "%.1f", b - a }')
ok "smoke test passed: RTO $rto s (restore started to smoke test passed)"

# --- 8. RPO -----------------------------------------------------------------------------------------------------------

lost=$((written - kept))
pitr_ok=null
if [[ $mode == pitr ]]; then
  gap=-
  if [[ $last_kept != - ]]; then
    gap=$(psql_ postgres -c "select extract(epoch from timestamptz '$target' - timestamptz '$last_kept')")
  fi
  if [[ $gap != - && $lost_after_target == 0 ]] && awk -v g="$gap" 'BEGIN { exit !(g >= 0 && g < 1) }'; then
    pitr_ok=true
    ok "PITR: newest marker back $last_kept, ${gap}s before the target $target; none after it ($kept of $written kept)"
  else
    pitr_ok=false
  fi
fi
rpo_at_least=false
if [[ $last_kept == - ]]; then
  rpo=$(psql_ postgres -c "select round(extract(epoch from timestamptz '$deleted_at' - timestamptz '$first_marker')::numeric, 3)")
  [[ $rpo =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "work out the RPO's lower bound (got '$rpo')"
  rpo_at_least=true
  echo "note  no marker of this run came back: the restore ended before the first one, written at $first_marker; RPO at least $rpo s (deletion at $deleted_at, WAL switch forced: $forced)"
else
  ok "RPO $rpo s: deletion at $deleted_at, newest marker back $last_kept; $kept of $written markers kept, $lost lost (WAL switch forced: $forced)"
fi
changed=$(LC_ALL=C join -t $'\t' -a 1 -a 2 -e - -o 0,1.2,2.2 "$work/counts-before" "$work/counts-after" | awk -F '\t' '$2 != $3' | wc -l | tr -d ' ')
ok "row counts of the services' tables: $changed of $(wc -l <"$work/counts-before" | tr -d ' ') differ after the restore"

# --- 9. Backup of the new generation ----------------------------------------------------------------------------------

new_backup=svp-pg-drill-$(date -u +%Y%m%d%H%M%S)
pg_backup "$new_backup"
declare_time new_backup
wait_until 300 "WAL archiving of the new generation (condition ContinuousArchiving True)" \
  test_output True condition ContinuousArchiving
ok "Backup $new_backup of generation $new_gen completed, WAL archiving on"

result=pass
[[ $pitr_ok != false ]] || result=fail
out="$drills/backup-$stamp.json"
jq -n --arg mode "$mode" --arg result "$result" --arg run "$run" \
  --arg from "$old_gen" --arg to "$new_gen" --arg base_backup "$base_backup" --arg new_backup "$new_backup" \
  --argjson forced "$forced" --arg last_wal "$last_wal" --arg last_wal_time "$last_wal_time" \
  --arg deleted_at "$deleted_at" --arg target "$target" --argjson pitr_ok "$pitr_ok" \
  --argjson written "$written" --argjson kept "$kept" --argjson lost "$lost" --arg last_kept "$last_kept" \
  --argjson rpo "$rpo" --argjson rpo_at_least "$rpo_at_least" --arg first_marker "$first_marker" \
  --argjson rto "$rto" --arg restarted "${restarted[*]}" \
  --argjson before "$(counts_json "$work/counts-before")" --argjson after "$(counts_json "$work/counts-after")" \
  --argjson t "$(jq -n --arg start "$t_start" --arg base "$t_base_backup" --arg markers "$t_markers" \
    --arg del "$t_delete" --arg deleted "$t_deleted" --arg t0 "$t_t0" --arg ready "$t_ready" \
    --arg restarted "$t_restarted" --arg t1 "$t_t1" --arg nb "$t_new_backup" '{
      start: ($start | tonumber), base_backup_completed: ($base | tonumber), markers_written: ($markers | tonumber),
      delete_started: ($del | tonumber), deleted: ($deleted | tonumber), restore_started_t0: ($t0 | tonumber),
      cluster_ready: ($ready | tonumber), workloads_restarted: ($restarted | tonumber),
      smoke_passed_t1: ($t1 | tonumber), new_backup_completed: ($nb | tonumber)}')" '{
    drill: "backup", mode: $mode, result: $result, run: $run,
    generations: {from: $from, to: $to}, backups: {base: $base_backup, new_generation: $new_backup},
    times_unix: $t,
    rto_seconds: $rto,
    rpo: {
      seconds: $rpo, at_least: $rpo_at_least, deleted_at: $deleted_at,
      forced_wal_switch: $forced, last_archived_wal: $last_wal, last_archived_time: $last_wal_time,
      markers_written: $written, markers_kept: $kept, markers_lost: $lost, first_marker_written_at: $first_marker,
      newest_marker_kept: (if $last_kept == "-" then null else $last_kept end)},
    pitr: (if $mode == "pitr" then {target_time: $target, ok: $pitr_ok} else null end),
    restarted_once: ($restarted | split(" ")),
    row_counts: {before: $before, after: $after}}' >"$out"
phase=done
echo "JSON: $out"
[[ $result == pass ]] ||
  fail "PITR: the newest marker back ($last_kept) must be at or before the target $target and less than 1 s before it, none after it (gap ${gap}s, $lost_after_target after)"
ok "backup drill ($mode) passed: RTO $rto s, RPO $([[ $rpo_at_least == false ]] || echo "at least ")${rpo}s"
