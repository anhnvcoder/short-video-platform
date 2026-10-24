#!/usr/bin/env bash
# Drill: the stage 4 rows of the threat model (docs/threat-model.md, section 5) on cluster svp
# (docs/adr/0014-kubernetes-local-stage4.md, sections 3 to 5 and 8 to 10), the web client's rows of stage 5b part C
# (section 4.9; docs/adr/0019-web-k3d-supply-chain-observability.md) and the stage 6 row of the backups of Postgres
# (BAK-1, section 4.10; docs/adr/0020-reliability-stage6.md, section 5). Every item prints ok and FAIL lines, and
# "ok    control:" lines: a target a check finds closed answers a client the policy lets in, so "closed" means the
# policy, not a service that is down. An item that fails does not stop the next ones; a table of PASS/FAIL per item
# ends the run, which exits non-zero when any failed:
#   IN-2/IN-4  a pod in namespace svp-probe (created by the drill, PSA restricted enforced, the image media-worker runs:
#              busybox nc and nslookup) resolves every name below but connects to none: gRPC 9101-9104, gateway 8080,
#              web 3001, Redpanda Kafka 9092 and Admin API 9644, Postgres 5432, Valkey 6379, MinIO 9000. Controls:
#              /readyz through Envoy (the gateway reaches user-, video- and feed-service), the explore feed of a drill
#              user with stats on every item, in one of up to 3 pages (the gateway reaches engagement-service, which
#              /readyz leaves out on purpose), /healthz (Envoy reaches the gateway), media-worker reaches Kafka and
#              MinIO, Prometheus has up{job="redpanda"} == 1 from a scrape under 120 s old (the Collector scrapes 9644),
#              GlitchTip's pod opens 5432, a login leaves its rate limit key in Valkey (the gateway reaches 6379),
#              MinIO's health through Envoy, the web client's /healthz through Envoy (Envoy reaches web:3001);
#   IN-4/FF-6  each Kafka user (password from Secret svp-data/kafka-users, passed on stdin, never printed) runs rpk in
#              the broker container: producing to a topic not its own is TOPIC_AUTHORIZATION_FAILED (svp-keda, which may
#              write no topic, gets no producer id: CLUSTER_AUTHORIZATION_FAILED), producing to its own topic works
#              with an idempotent producer and WRITE on that topic only, describing the group of another service is
#              GROUP_AUTHORIZATION_FAILED, its own works; media-worker cannot produce to video.lifecycle.v1, nor read
#              another service's topic. Test records: see "Test records" below. The Admin
#              API refuses node_config, cluster_config, security/users and brokers without credentials and serves
#              /public_metrics; control: rpk with the broker's own login reads admin_api_require_auth (true);
#   FF-5       from media-worker (kubectl exec): the internet (an IP and a name), the gateway, the four gRPC
#              services, Postgres, Valkey and the API server are closed; MinIO, Kafka and the Collector open. Controls
#              as above, and the probe pod (namespace without egress policy) reaches the API server;
#   FF-3/FF-4  every container of every pod in svp has CPU and memory requests and limits, runAsNonRoot,
#              readOnlyRootFilesystem, drops ALL and adds nothing, allowPrivilegeEscalation false, seccomp
#              RuntimeDefault (a container's own runAsNonRoot and seccomp override the pod's), no host namespace or
#              hostPath, and no ServiceAccount token reaches it: automount off, no volume of a projected
#              serviceAccountToken or of a Secret of type service-account-token (on its own or as a source of a
#              projected volume) mounted at any path, no such Secret in its env or envFrom; the project's namespaces
#              enforce PSA restricted; the kubelet of every node has podPidsLimit as in deploy/k8s/k3d.yaml. Every pod
#              of svp is checked, not a list, and each pod of the web client (labels app.kubernetes.io/name=web,
#              component=server) must be among them, its containers named. Controls: the same check flags every rule on
#              a bare pod, and on a pod that is restricted but for a container's runAsNonRoot false and a token reaching
#              a container in each of those ways, while a container with an ordinary Secret as a volume and in envFrom
#              passes; a server-side dry run of a root pod in svp is Forbidden while a restricted one is admitted;
#   IN-9       the pg_hba rules of the primary have no trust, every TCP rule is scram-sha-256 or cert, the last rule is
#              host all all all scram-sha-256 (CloudNativePG's default, ADR-0014 section 4); from GlitchTip's pod (allowed
#              to 5432) a connection without a password, as postgres and as svp_user_app, with and without TLS, is
#              refused with "no password supplied", a wrong password with "password authentication failed"; inside
#              the primary, TCP to 127.0.0.1 without a password is refused too (the stage 1 hole of the host's
#              Postgres was trust on loopback);
#   RL-1       after every login-ip bucket in Valkey has expired (GCRA: a key lives until its bucket is full again, at
#              most 30 s; none is deleted), 40 wrong logins through https://api.svp.localhost:8443 over one HTTP/2
#              connection (so one client address at the gateway), 8 in flight at a time, each with a new email and
#              its own forged X-Forwarded-For: 30 (the burst of login-ip) pass the rate limit, plus one for each
#              second the decisions spread over (the bucket refills one per second; the spread is read from the
#              login-email keys, which hold the time of each decision), and the rest get 429 RATE_LIMITED, at least
#              one; the login-email key of every email that passed exists and of none that got 429 (so the 429 came
#              from login-ip, which is checked first); the login-ip keys added are at most 2 (k3d: one per node, ADR-0014
#              section 9), on the pod network 10.42.0.0/16, none for a forged address. These are judged on an
#              attempt in which no login decision fell back to a gateway pod's in-memory limiter (a Valkey call over
#              the gateway's 50 ms takes that path, with its own burst per pod): on every gateway pod, the fallback
#              login decisions of svp_ratelimit_decisions_total are the same in a sample after the burst as in its
#              last one before it. An attempt with a fallback decision, or one where that cannot be told, is printed
#              and does not count, as does one in which the gateway's pods changed (a new, ended, deleted or
#              restarted one: the instance label of the samples, random per process, names no pod); the drill tries
#              again once the bucket is full, at most 3 attempts in all;
#   OPS-1      /debug/pprof/, /debug/pprof/heap and /metrics through Envoy are 404; control: /healthz 200;
#   OPS-2      the only routes are HTTPRoute svp/api, svp/web and svp-data/s3 (to gateway, web and minio; svp.localhost
#              to web and web-canary), no other route kind or
#              Ingress, the only LoadBalancer or NodePort Service is Envoy's, no pod outside kube-system uses the
#              host network or a hostPort; grafana, prometheus, alertmanager, glitchtip and argocd .svp.localhost are
#              404 at Envoy; Grafana without a login is 401 (port-forward on 127.0.0.1:13000, started and stopped by
#              the drill). Controls: api.svp.localhost/healthz 200, Grafana's /api/health 200 and /api/user with the
#              admin login (Secret svp-obs/grafana-admin, through a private curl config file) 200;
#   RBAC       no ServiceAccount of namespace svp may get or list secrets or pods in any namespace of the cluster
#              (every one it has when the drill runs, not a fixed list) or cluster-wide (kubectl auth can-i --as), and
#              in no namespace does a rule of its SelfSubjectRulesReview let it get, list or watch them, by name or not
#              (can-i asked without a name says no to a Role that grants only named objects). Controls: the rule check
#              flags exactly the named, the watch and the wildcard rules of a sample review, and finds the Argo
#              Rollouts controller's right to list pods in svp, to which can-i says yes as well. Operators: the
#              CloudNativePG operator may get and list Secrets in cnpg-system and svp-data only, create pods, exec
#              into them, patch Deployments, create ServiceAccounts and delete Secrets in svp-data only, and create a
#              ServiceAccount token nowhere; as it, in cnpg-system (server-side dry runs), a token Secret for
#              ServiceAccount plugin-barman-cloud, the same named cnpg-ca-secret and an Opaque Secret of another name
#              are refused by ValidatingAdmissionPolicy svp-cnpg-operator-secrets, and so is a label on another TLS
#              Secret there (controls: as it, an Opaque cnpg-ca-secret passes the policy and is AlreadyExists, a
#              label on cnpg-webhook-cert passes; as the drill's admin, the token Secret is admitted); the Envoy
#              Gateway controller get and list Secrets in the namespaces it watches only
#              (envoy-gateway-system, svp, svp-data, svp-edge) and patch pods nowhere, Kyverno's admission and reports
#              controllers get and list Secrets in kyverno only, neither cluster-wide (can-i in every namespace and
#              -A); the exceptions (cert-manager, Argo CD, Kyverno, the Barman Cloud plugin) are printed as info with
#              their reason;
#   PSA-platform every namespace but kube-system, kube-public, kube-node-lease and default (the platform charts'
#              included: cert-manager, envoy-gateway-system, cnpg-system, keda, argo-rollouts, kyverno, argocd on the
#              GitOps path) enforces PSA restricted at the podSecurityVersion of chart svp-cluster, and every
#              namespace of deploy/argocd/apps/components.json exists; default, kube-public and kube-node-lease carry
#              no PSA label and the cluster default (deploy/k8s/pod-security-admission.yaml) refuses a privileged pod
#              with the node's / as hostPath there, restricted at that version (server-side dry run). Control: a
#              restricted pod is admitted in each. kube-system, exempt from the default, is printed as info with its
#              reason;
#   WEB-7      a drill user registers through the web client's /register form at https://svp.localhost:8443 (posted as a
#              browser without JavaScript posts it: the form's hidden Server Action fields, read from the page, then the
#              user's fields; the session cookie __Host-Http-svp_sid stays in a private cookie jar). With that session,
#              /api/ paths outside the BFF's list are 400 or 404: unknown and gateway-only routes, `..` (sent as is),
#              %2F, an internal host in the path, an unknown query parameter; a path with %2F may instead get Envoy's
#              own 307 to the unescaped path (Envoy Gateway's default UnescapeAndRedirect), whose Location must stay on
#              the web client's origin with no escaped slash and answer 400 or 404 in turn. Its HTML pages (/, /me,
#              /upload, /u/<handle>), the RSC payloads of / and /me and the JSON of /api/me and /api/feed/explore hold
#              no string shaped like a JWT (eyJ.., three dot-separated parts), nor the session's own access token,
#              refresh token or session id (read from the session in Valkey db 9, never printed). Controls:
#              /api/feed/explore and /api/me are 200 (handle of the drill user), /me renders the handle (the pages were
#              rendered with the session), the RSC answers are text/x-component, and the same JWT search finds the token
#              of a login answered by the gateway itself (https://api.svp.localhost:8443) and the session's access
#              token;
#   WEB-2      POSTs carrying the drill user's session cookie to a Server Action (the /login form), /api/videos (an
#              empty JSON object), /logout, /rum and /monitoring with Sec-Fetch-Site cross-site or same-site, Origin
#              https://evil.example, https://s3.svp.localhost:8443 (same site: it serves files users uploaded) or null,
#              or with neither header, are 403 CSRF_REJECTED, and after the refused logouts the session still works.
#              Controls: the same POSTs with Sec-Fetch-Site same-origin and the app's Origin are not refused: the login
#              action renders its form with "Wrong email or password" in the form's alert (200), the empty upload
#              request reaches the gateway (400, its own code), /rum takes a beacon (204), /monitoring checks the body
#              (400 INVALID_REPORT), and /logout (303) clears the cookie and ends the session on the server: the old
#              session id sent again gets 401 from /api/me;
#   WEB-10     preflights (OPTIONS) to MinIO through Envoy, /media/... (GET) and /uploads (POST) at
#              https://s3.svp.localhost:8443, from https://evil.example and from the compose origins
#              http://localhost:3001 and :3002 get no Access-Control-Allow-Origin; control: from
#              https://svp.localhost:8443 they get exactly that origin;
#   WEB-13     from each web pod (kubectl exec of the image's node, /nodejs/bin/node -e: distroless has no shell; a name
#              is resolved first, so a closed port with a name that resolves is the policy): the internet (an IP and a
#              name), Postgres, Redpanda (9092, 9644), MinIO, the four gRPC services, Pyroscope and the API server are
#              closed; the gateway 8080, Valkey 6379, the Collector 4317 and GlitchTip 8000 open (the controls of the
#              closed ones). The probe pod of svp-probe cannot open web:3001; control: Envoy reaches it (/healthz 200);
#   WEB-8      once every login-ip bucket has expired, 40 wrong logins through the web client's /login form (the Server
#              Action, each with a new email and its own forged X-Forwarded-For) over one HTTP/2 connection to Envoy, 8
#              in flight at a time: every answer is the form whose alert reads "Wrong email or password" or "Too many
#              tries" (any 429 of the gateway), at least one is a 429 of login-ip (no login-email key for its email),
#              every 401 left its login-email key; the login-ip keys added are 1 or 2, on the pod network of a node and
#              none the address of a web pod (which would put every web user in one bucket), no key is for a forged
#              address, and the login-email key of every login that passed names one of those addresses: the gateway
#              counts the address Envoy wrote, which the web client passes on unchanged;
#   BAK-1      S3 requests to MinIO through Envoy (https://s3.svp.localhost:8443), signed (AWS Signature V4) with the
#              MinIO logins of Secrets svp-data/pg-backup-s3 and svp-data/minio-users (in private curl config files,
#              never on a command line): svp-pg-backup may neither list buckets uploads and media nor read an object
#              there, 403 AccessDenied (media's objects are public to anonymous GETs by design, UP-6: this checks the
#              user's own policy), and svp-video-service and svp-media-worker may neither list pg-backups nor read an
#              object there. The objects read are a name of this run, which exists nowhere: MinIO answers 404 NoSuchKey
#              where the user may read and 403 AccessDenied where not, so nothing of a backup is downloaded. Controls:
#              svp-pg-backup lists pg-backups (200) and reads there (404 NoSuchKey), each service's user reads its
#              own prefix uploads/uploads/ (404 NoSuchKey). Other pods cannot reach MinIO (IN-2, FF-5, WEB-13), and
#              the Barman Cloud plugin's RBAC is printed with its reason (RBAC).
#
# Test records: the drill writes one empty record (key drill-threats-<run>, header svp-drill=threats) to the
# dead-letter topic of each user that has one; nothing consumes a dead-letter topic, and the dead-letter metric is
# counted by the services, not the broker. user-service owns no dead-letter topic: its right to produce to
# user.follows.v1 is shown with a record larger than the broker's 1 MiB limit, which the broker refuses with
# MESSAGE_TOO_LARGE once the user is authorized and with TOPIC_AUTHORIZATION_FAILED otherwise (shown by the same
# oversized record from feed-service, which may read user.follows.v1 but not write it), so no record reaches a topic a
# service consumes; the high watermarks of the four topics are compared before and after (a topic rpk cannot read
# fails the check rather than counting as unchanged).
#
# On any exit the drill deletes namespace svp-probe (waiting until it is gone), stops its two port-forwards
# (Prometheus 127.0.0.1:19090, Grafana 127.0.0.1:13000) by their pids and logs the web session out if it is still on.
# Its whole output goes to .k8s/drills/threats-<time>.log too, which is searched afterwards for every Secret value the
# drill read: a line holding one fails the run. Reads Postgres (SELECT on pg_hba_file_rules) and Valkey (SCAN, PTTL,
# MGET in db 10; GET of the drill user's own session in db 9) only.
#
# Usage (from the repo root, cluster up): make drill-k8s-threats. LOCAL LAB ONLY: the drill deletes the register rate
# limit keys in the cluster's Valkey db 10 (deploy/compose/lib.sh), and registers two users (one at the gateway, one
# through the web client).
set -euo pipefail

# The drill runs twice over: this first part runs the second as a child, its output through tee to the log, then
# looks for the Secret values in that log, which is complete only once the child has ended.
if [[ -z ${SVP_THREATS_LOG:-} ]]; then
  # shellcheck source=deploy/k8s/lib.sh
  source "$(dirname "$0")/../lib.sh"
  mkdir -p "$repo_root/.k8s/drills"
  log="$repo_root/.k8s/drills/threats-$(date -u +%Y%m%dT%H%M%SZ).log"
  values=
  trap '[ -z "$values" ] || rm -f "$values"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  set +e
  # tee ignores Ctrl-C (an ignored signal stays ignored across exec): it keeps reading until the child has cleaned up,
  # so the child's last lines are not lost to a broken pipe and reach the log.
  SVP_THREATS_LOG=$log "$0" "$@" 2>&1 | (
    trap '' INT
    exec tee "$log"
  )
  rc=${PIPESTATUS[0]}
  set -e
  # The Secret values the drill read, one per line in a private file, for grep -F -f: never an argument, never printed.
  values=$(mktemp)
  {
    kc -n svp-data get secret kafka-users -o json | jq -r '.data[] | @base64d'
    kc -n svp-obs get secret grafana-admin -o json | jq -r '.data["admin-password"] | @base64d'
    kc -n svp-data get secret pg-backup-s3 -o json | jq -r '.data.ACCESS_SECRET_KEY | @base64d'
    kc -n svp-data get secret minio-users -o json |
      jq -r '.data.SVP_VIDEO_S3_SECRET_KEY, .data.SVP_MEDIA_WORKER_S3_SECRET_KEY | @base64d'
  } | grep -v '^$' >"$values" || true
  n=$(wc -l <"$values" | tr -d ' ')
  if ((n < 10)); then
    echo "FAIL  SECRETS: read the 10 Secret values the drill used (6 Kafka users, Grafana admin, 3 MinIO users) to search its output (got $n)" | tee -a "$log" >&2
    exit 1
  fi
  leaks=$(grep -c -F -f "$values" "$log" || true)
  if [[ $leaks != 0 ]]; then
    echo "FAIL  SECRETS: $leaks line(s) of the drill's output hold one of the $n Secret values it read (${log#"$repo_root"/})" | tee -a "$log" >&2
    exit 1
  fi
  echo "ok    SECRETS: none of the $n Secret values the drill read (6 Kafka users, Grafana admin, 3 MinIO users) is in its output (${log#"$repo_root"/})" | tee -a "$log"
  exit "$rc"
fi

base=${1:-https://api.svp.localhost:8443}
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

run_id=$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 2)
probe_ns=svp-probe
probe_owner=svp-drill-threats
# The Pod Security Standard version chart svp-cluster pins, which namespace svp-probe enforces as well: PSA-platform
# checks it like every other namespace, and FF-4 expects it on the project's namespaces and in the admission message.
psa_version=$(sed -n 's/^podSecurityVersion: *//p' "$repo_root/deploy/helm/svp-cluster/values.yaml")
[[ $psa_version =~ ^v1\.[0-9]+$ ]] ||
  fail "read podSecurityVersion in deploy/helm/svp-cluster/values.yaml (got '$psa_version')"
grafana_port=13000
grafana_pid=
probe_created=

drill_exit() {
  local rc=$?
  trap - EXIT
  # Every step of the cleanup runs, whatever the one before it returned.
  set +e
  prometheus_stop
  if [ -n "$grafana_pid" ]; then
    kill "$grafana_pid" 2>/dev/null || true
    wait "$grafana_pid" 2>/dev/null || true
  fi
  # The web session lives 30 days; an item that failed before WEB-2's logout leaves it on.
  if [ -n "$(web_sid)" ]; then
    [[ $(web_post /logout "$work/web-logout" -H "Sec-Fetch-Site: same-origin" -H "Origin: $web_base") == 303 ]] &&
      ok "web session of the drill user logged out" ||
      echo "info  the web session's logout did not answer 303: it ends with its TTL"
  fi
  if [ -n "$probe_created" ]; then
    if probe_delete; then
      ok "namespace $probe_ns deleted"
    else
      echo "FAIL  delete namespace $probe_ns; run: kubectl --context k3d-svp delete namespace $probe_ns" >&2
      rc=1
    fi
  fi
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# miss MESSAGE: one failed check of the current item, which goes on with its other checks and fails at its end.
miss() {
  echo "FAIL  $1" >&2
  item_failed=1
}
# control MESSAGE: a control case passed.
control() { echo "ok    control: $1"; }
info() { echo "info  $1"; }

# valkey ARGS...: valkey-cli on the gateway's db 10 inside the Valkey pod (it has no address on the host); the drill
# only reads with it.
valkey() { kc -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 10 "$@"; }

# email_hash EMAIL: the part of the login-email key the gateway derives from EMAIL (ratelimit.LoginEmailID: first 32
# hex characters of the SHA-256 of the lower-cased email).
email_hash() { printf '%s' "$1" | tr 'A-Z' 'a-z' | shasum -a 256 | cut -c1-32; }

# wrong_login EMAIL: POST /auth/login with EMAIL and a random password; prints the HTTP status.
wrong_login() {
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$1" '{email: $e, password: env.DRILL_PASSWORD}' >"$work/login.json"
  request POST /auth/login "" "$work/login.json"
}

# The web client, behind listener https-apex of Gateway svp, and MinIO's route, which is the same site.
web_base=https://svp.localhost:8443
s3_origin=https://s3.svp.localhost:8443
web_cookie=__Host-Http-svp_sid
# The web pods: a Rollout's, so kubectl exec names a pod, not deploy/web.
web_selector=app.kubernetes.io/name=web,app.kubernetes.io/component=server

# web_get PATH OUT [CURL_ARGS...] / web_post PATH OUT [CURL_ARGS...]: a request to the web client with the drill user's
# session (the private cookie jar $work/web.jar, kept up to date; web_jar names another one, such as an empty one for a
# logged-out request); the body goes to OUT, the response headers to OUT.headers, and the HTTP status is printed (000
# when nothing answered). Accept-Language en: the form errors the drill reads are the English copy. Redirects are not
# followed.
web_get() { web_curl GET "$@"; }
web_post() { web_curl POST "$@"; }
web_curl() {
  local method=$1 path=$2 out=$3 jar=${web_jar:-$work/web.jar}
  shift 3
  : >"$out"
  touch "$jar"
  curl -sS --max-time 15 -X "$method" -o "$out" -D "$out.headers" -w '%{http_code}' -b "$jar" -c "$jar" \
    -H 'Accept-Language: en' "$@" "$web_base$path" || true
}

# web_sid: the session id in the cookie jar, "" when there is none. Never printed: callers only test or hash it.
web_sid() {
  [[ -f $work/web.jar ]] || return 0
  awk -F '\t' -v n="$web_cookie" '$6 == n { v = $7 } END { print v }' "$work/web.jar"
}

# form_fields HTML_FILE: the hidden inputs of the form that has a password field in HTML_FILE, as curl config lines
# (form-string = "NAME=VALUE", HTML entities decoded); fails when there is none. A form whose action is a Server Action
# carries the action's id and bound state in such inputs ($ACTION_...), which is how a browser without JavaScript posts
# it: a multipart POST of those fields and the user's, to the page's own URL.
form_fields() {
  perl -0777 -ne '
    my $form;
    while (/(<form\b.*?<\/form>)/sg) { my $f = $1; if ($f =~ /name="password"/) { $form = $f; last } }
    defined $form or exit 1;
    my $n = 0;
    while ($form =~ /<input\b([^>]*)>/sg) {
      my $a = $1;
      next unless $a =~ /\btype="hidden"/;
      my ($name) = $a =~ /\bname="([^"]*)"/ or next;
      my ($value) = $a =~ /\bvalue="([^"]*)"/;
      $value = "" unless defined $value;
      for ($name, $value) {
        s/&quot;/"/g; s/&#x27;|&#39;/\x27/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/&/g;
        s/\\/\\\\/g; s/"/\\"/g;
      }
      print "form-string = \"$name=$value\"\n";
      $n++;
    }
    exit($n ? 0 : 1);
  ' "$1"
}

# web_form_config PAGE FIELDS_FILE OUT: a curl config (written to OUT) that posts the form of PAGE as a browser without
# JavaScript does, with the fields of FIELDS_FILE (a JSON object, as new_user writes credentials: values reach curl in
# this private file, never on a command line). No Origin or Sec-Fetch-Site: the caller adds them. Reads the page first
# (with the session of the cookie jar, or of web_jar).
web_form_config() {
  local status
  status=$(web_get "$1" "$work/form.html")
  [[ $status == 200 ]] || fail "GET $1 of the web client is 200 (status $status)"
  {
    echo "url = \"$web_base$1\""
    echo 'header = "Accept-Language: en"'
    form_fields "$work/form.html" || fail "the form of $1 has hidden Server Action fields"
    jq -r 'to_entries[] | "form-string = \("\(.key)=\(.value)" | @json)"' "$2"
  } >"$3"
}

# web_form PAGE FIELDS_FILE: posts the form of PAGE (web_form_config) with the session of the cookie jar and the app's own
# Origin, as the CSRF check wants; the answer goes
# to $work/form.out, and form_status is set to the HTTP status: 303 when the action redirects (signed in), 200 when the
# form comes back with an error. Sets a variable instead of printing, like key_records of the compose drills: a fail
# inside $(...) would only end the subshell. Call it as a plain command.
web_form() {
  web_form_config "$1" "$2" "$work/form.curl"
  : >"$work/form.out"
  form_status=$(curl -sS --max-time 15 -o "$work/form.out" -w '%{http_code}' -b "$work/web.jar" -c "$work/web.jar" \
    -K "$work/form.curl" -H "Origin: $web_base" || true)
}

# form_error FILE: the error the form with a password field in FILE shows, by its English copy (messages/en/auth.json):
# wrong-credentials, rate-limited, unavailable (the box of the whole form, role="alert", by its title), email-taken,
# handle-taken, invalid (the red note under a field, class text-danger), other (an alert or note with other copy), none
# (neither), no-form (FILE has no such form: a redirect, an error page). Only the form's own markup is read: every
# page of /login and /register also carries all the auth messages, unrendered, in its RSC payload (scripts outside the
# form), so a search of the whole page finds "Wrong email or password" in a form that shows nothing.
form_error() {
  perl -0777 -ne '
    my $form;
    while (/(<form\b.*?<\/form>)/sg) { my $f = $1; if ($f =~ /name="password"/) { $form = $f; last } }
    defined $form or do { print "no-form\n"; exit 0 };
    my $alert = $form =~ /\brole="alert"[^>]*>(.*?)<\/strong>/s ? $1 : "";
    my $notes = join " ", $form =~ /<p\b[^>]*\bclass="[^"]*\btext-danger\b[^"]*"[^>]*>(.*?)<\/p>/sg;
    s/<[^>]*>//g for $alert, $notes;
    if ($alert =~ /Wrong email or password/) { print "wrong-credentials\n" }
    elsif ($alert =~ /Too many tries/) { print "rate-limited\n" }
    elsif ($alert =~ /The service is busy/) { print "unavailable\n" }
    elsif ($notes =~ /This email is already in use/) { print "email-taken\n" }
    elsif ($notes =~ /This username is taken/) { print "handle-taken\n" }
    elsif ($notes =~ /Enter a valid email|The password needs|A username needs/) { print "invalid\n" }
    elsif ($alert =~ /\S/ || $notes =~ /\S/) { print "other\n" }
    else { print "none\n" }
  ' "$1"
}

# web_user: the drill's web user, registered through the web client's /register form on first use (the register action
# logs the new user in); its credentials and handle stay in $work/web.cred, its session in the cookie jar.
web_user() {
  local handle email
  [[ -s $work/web.cred && -n $(web_sid) ]] && return 0
  handle=drill_$(openssl rand -hex 6)
  email="drill-web-$run_id-$(openssl rand -hex 4)@example.test"
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" --arg h "$handle" \
    '{email: $e, password: env.DRILL_PASSWORD, handle: $h}' >"$work/web-new.cred"
  : >"$work/web.jar"
  web_form /register "$work/web-new.cred"
  [[ $form_status == 303 && -n $(web_sid) ]] ||
    fail "register a user through the web client's /register form: 303 with cookie $web_cookie (status $form_status, form error $(form_error "$work/form.out"))"
  mv "$work/web-new.cred" "$work/web.cred"
  ok "user @$handle registered through the web client's /register form (no JavaScript, Server Action): 303, session cookie $web_cookie in the drill's cookie jar"
}

# web_tokens: the drill user's web session, read from Valkey db 9 (key svp:web:sess:<SHA-256 of the sid>, the web
# client's session store), as "NAME<TAB>VALUE" lines in $work/web.tokens: access-token, refresh-token, sid. The values
# stay in that private file; the sid reaches jq through its environment.
web_tokens() {
  local sid key
  sid=$(web_sid)
  [[ -n $sid ]] || fail "the web session cookie is in the drill's cookie jar"
  key="svp:web:sess:$(printf '%s' "$sid" | shasum -a 256 | cut -c1-64)"
  kc -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 9 GET "$key" >"$work/web.session" ||
    fail "read the drill user's web session in Valkey db 9"
  WEB_SID=$sid jq -r '"access-token\t\(.access_token // "")", "refresh-token\t\(.refresh_token // "")", "sid\t\(env.WEB_SID)"' \
    "$work/web.session" >"$work/web.tokens" 2>/dev/null || : >"$work/web.tokens"
  rm -f "$work/web.session"
  [[ $(awk -F '\t' '$2 != ""' "$work/web.tokens" | wc -l | tr -d ' ') == 3 ]] ||
    fail "the drill user's web session in Valkey db 9 (svp:web:sess:<SHA-256 of the sid>) has an access and a refresh token"
}

# holds VALUES_FILE FILE: the names of the values of VALUES_FILE ("NAME<TAB>VALUE[<TAB>i]" lines; i: any case) that
# FILE holds, space-separated, "" when none. awk reads the values from the file, never from its command line.
holds() {
  awk -F '\t' 'NR == FNR { n++; name[n] = $1; val[n] = $2; ci[n] = ($3 == "i"); next }
    { s = s $0 "\n" }
    END {
      l = tolower(s)
      for (i = 1; i <= n; i++) {
        if (val[i] == "") continue
        if (ci[i] ? index(l, tolower(val[i])) : index(s, val[i])) out = out " " name[i]
      }
      print substr(out, 2)
    }' "$1" "$2"
}

# jwt_shaped FILE: true when FILE holds a string shaped like a JWT: eyJ (base64url of {") and three dot-separated
# base64url parts, as every token of the gateway is.
jwt_shaped() { grep -qE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$1"; }

# web_pods: "NAME IP" of every running web pod.
web_pods() {
  kc -n svp get pods -l "$web_selector" --field-selector status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}'
}

# probe_delete: deletes namespace svp-probe and waits until it is gone; true when it is.
probe_delete() {
  kc delete namespace "$probe_ns" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  ! kc get namespace "$probe_ns" >/dev/null 2>&1
}

# probe_up: namespace svp-probe (PSA restricted enforced, no NetworkPolicy) with pod probe, in the image media-worker
# runs (pulled from the cluster's own registry), which has busybox nc and nslookup; the pod meets the restricted
# standard, or the namespace would refuse it. A namespace of that name left by a killed run (it carries the drill's
# label) is deleted first; one without the label is someone else's and stops the drill.
probe_up() {
  local owner
  if kc get namespace "$probe_ns" >/dev/null 2>&1; then
    owner=$(kc get namespace "$probe_ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')
    [[ $owner == "$probe_owner" ]] ||
      fail "namespace $probe_ns exists without label app.kubernetes.io/managed-by=$probe_owner: not this drill's, delete it yourself"
    probe_delete || fail "delete namespace $probe_ns left by an earlier run"
  fi
  worker_image=$(kc -n svp get deployment media-worker -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ -n $worker_image ]] || fail "read the image of deployment svp/media-worker"
  probe_created=1
  kc apply -f - >/dev/null <<EOF || fail "create namespace $probe_ns and pod probe"
apiVersion: v1
kind: Namespace
metadata:
  name: $probe_ns
  labels:
    app.kubernetes.io/managed-by: $probe_owner
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: $psa_version
---
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: $probe_ns
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $worker_image
      command: ["sleep", "900"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 200m, memory: 64Mi}
EOF
  kc -n "$probe_ns" wait --for=condition=Ready pod/probe --timeout=120s >/dev/null ||
    fail "pod $probe_ns/probe Ready within 120s"
  ok "namespace $probe_ns (PSA restricted enforced, no NetworkPolicy) with pod probe ($worker_image) Ready"
}

# reach NAMESPACE TARGET HOST:PORT...: from TARGET (as kubectl exec names it: pod/probe, deploy/media-worker) in
# NAMESPACE, writes "HOST PORT DNS STATE" per target to $work/reach: DNS is dns when the name resolves (busybox
# nslookup), nodns when not, ip for an address; STATE is open when a TCP connection opens within 3 s (busybox nc -z),
# closed otherwise.
reach() {
  local ns=$1 target=$2
  shift 2
  kc -n "$ns" exec "$target" -- sh -c '
    for t in "$@"; do
      h=${t%:*} p=${t##*:}
      case $h in
        *[!0-9.]*) if nslookup "$h" >/dev/null 2>&1; then d=dns; else d=nodns; fi ;;
        *) d=ip ;;
      esac
      if timeout 5 nc -z -w 3 "$h" "$p" >/dev/null 2>&1; then s=open; else s=closed; fi
      echo "$h $p $d $s"
    done' sh "$@" >"$work/reach" || fail "run the connection probes in $ns/$target"
}

# expect_reach HOST:PORT open|closed WHAT: the line of HOST:PORT in $work/reach is STATE, and a name resolved.
expect_reach() {
  local h=${1%:*} p=${1##*:} got
  got=$(awk -v h="$h" -v p="$p" '$1 == h && $2 == p { print $3, $4 }' "$work/reach")
  case $got in
    "dns $2" | "ip $2") ok "$3 $1: $2" ;;
    "nodns "*) miss "$3 $1: the name resolves (it does not, so a closed port proves nothing)" ;;
    *) miss "$3 $1: $2 (got: ${got:-no answer})" ;;
  esac
}

# The controls: each shows a target answers a client the policy lets in.
control_readyz() {
  local status
  status=$(request GET /readyz)
  [[ $status == 200 ]] && control "/readyz through Envoy 200: the gateway reaches user-, video- and feed-service (9101, 9102, 9104)" ||
    miss "control: /readyz through Envoy is 200 (status $status)"
}
# control_engagement: /readyz leaves engagement-service out on purpose (the feed degrades to items without stats while
# it is down, so the gateway stays ready), so it proves nothing for 9103. The feed does: the gateway adds each item's
# stats from one GetStats call to engagement-service, and serves the items without stats when that call fails. That
# call has 100 ms and no retry (statsTimeout, services/gateway/internal/api/api.go), so under load one page can come
# without stats while engagement-service answers: up to 3 pages, 1 s apart, and any with stats on every item shows
# 9103 answered. One drill user per run, registered on first use; its Authorization header stays in $work for the
# items after.
control_engagement() {
  local status items with try
  [[ -s $work/drill.auth ]] || new_user drill
  for try in 1 2 3; do
    status=$(request GET "/feed/explore?page_size=10" "$work/drill.auth")
    items=$(jq '.items | length' "$work/body" 2>/dev/null || echo 0)
    with=$(jq '[.items[] | select(.stats != null)] | length' "$work/body" 2>/dev/null || echo 0)
    if [[ $status == 200 && $items -gt 0 && $with == "$items" ]]; then
      control "GET /feed/explore 200 with stats on all $items items (page $try of up to 3): the gateway reaches engagement-service (9103)"
      return 0
    fi
    ((try == 3)) || sleep 1
  done
  miss "control: GET /feed/explore is 200 with stats on every item, in one of 3 pages 1 s apart (last: status $status, $with of $items items with stats; an empty explore feed needs a READY video: run make k8s-smoke)"
}
control_healthz() {
  local status
  status=$(request GET /healthz)
  [[ $status == 200 ]] && control "/healthz through Envoy 200: Envoy reaches the gateway on 8080" ||
    miss "control: /healthz through Envoy is 200 (status $status)"
}
control_postgres() {
  kc -n svp-obs exec deploy/glitchtip -- python -c '
import socket
socket.create_connection(("svp-pg-rw.svp-data.svc.cluster.local", 5432), 5).close()' >/dev/null 2>&1 &&
    control "GlitchTip's pod (svp-obs) opens svp-pg-rw.svp-data:5432" ||
    miss "control: GlitchTip's pod opens svp-pg-rw.svp-data:5432"
}
# control_valkey: a login with a new email leaves its login-email key (svp:gw:rl:login-email:<ip>:<hash>, alive for an
# hour's sixth) in db 10, so the gateway reached Valkey. Costs one request of the login-ip bucket (refilled in 1 s).
# The email is new on every call: the key names the client address too, and two calls can reach the gateway through
# two nodes (ADR-0014 section 9), which would leave one key each.
control_valkey() {
  local email status keys
  email="drill-threats-$run_id-control-$(openssl rand -hex 4)@example.test"
  status=$(wrong_login "$email")
  keys=$(valkey --scan --pattern "svp:gw:rl:login-email:*:$(email_hash "$email")" | wc -l | tr -d ' ')
  [[ $status == 401 && $keys == 1 ]] &&
    control "a login (401) left its login-email key in Valkey db 10: the gateway reaches valkey.svp-data:6379" ||
    miss "control: a login is 401 and leaves its login-email key in Valkey db 10 (status $status, keys $keys)"
}
control_worker_data() {
  reach svp deploy/media-worker redpanda.svp-data.svc.cluster.local:9092 minio.svp-data.svc.cluster.local:9000
  expect_reach redpanda.svp-data.svc.cluster.local:9092 open "control: from media-worker"
  expect_reach minio.svp-data.svc.cluster.local:9000 open "control: from media-worker"
}
# control_redpanda_admin: the latest up{job="redpanda"} is 1 and its sample under 120 s old. The age comes from
# timestamp() of the plain selector: on an expression such as `up == 1` it returns the evaluation time instead.
control_redpanda_admin() {
  local up age
  up=$(promql 'up{job="redpanda"}' | jq -r 'if length > 0 and all(.[]; .value[1] == "1") then "1" else (map(.value[1]) | join(",")) end')
  age=$(promql 'time() - timestamp(up{job="redpanda"})' | jq -r 'map(.value[1] | tonumber) | max // empty')
  [[ $up == 1 && -n $age ]] && awk -v a="$age" 'BEGIN { exit !(a < 120) }' &&
    control "Prometheus has up{job=\"redpanda\"} == 1 from a scrape $(printf '%.0f' "$age") s ago: the Collector scrapes redpanda-0:9644" ||
    miss "control: Prometheus has up{job=\"redpanda\"} == 1 from a scrape under 120 s old (up '${up}', age '${age}')"
}
control_minio_edge() {
  local status
  status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "https://s3.svp.localhost:8443/minio/health/live" || true)
  [[ $status == 200 ]] && control "MinIO's /minio/health/live through Envoy 200: Envoy reaches minio:9000" ||
    miss "control: MinIO's /minio/health/live through Envoy is 200 (status $status)"
}
control_web_edge() {
  local status
  status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$web_base/healthz" || true)
  [[ $status == 200 ]] && control "the web client's /healthz through Envoy ($web_base) 200: Envoy reaches web:3001" ||
    miss "control: the web client's /healthz through Envoy is 200 (status $status)"
}

in2() {
  local t
  local targets=(
    user-service.svp.svc.cluster.local:9101 video-service.svp.svc.cluster.local:9102
    engagement-service.svp.svc.cluster.local:9103 feed-service.svp.svc.cluster.local:9104
    gateway.svp.svc.cluster.local:8080 web.svp.svc.cluster.local:3001 redpanda.svp-data.svc.cluster.local:9092
    redpanda-0.redpanda.svp-data.svc.cluster.local:9644 svp-pg-rw.svp-data.svc.cluster.local:5432
    valkey.svp-data.svc.cluster.local:6379 minio.svp-data.svc.cluster.local:9000
  )
  reach "$probe_ns" pod/probe "${targets[@]}"
  for t in "${targets[@]}"; do expect_reach "$t" closed "IN-2/IN-4: from $probe_ns"; done
  [[ $(awk '$3 == "dns"' "$work/reach" | wc -l | tr -d ' ') == "${#targets[@]}" ]] &&
    ok "IN-2/IN-4: DNS works from $probe_ns: all ${#targets[@]} names resolve, so each closed port is the policy"
  control_readyz
  control_engagement
  control_healthz
  control_worker_data
  control_redpanda_admin
  control_postgres
  control_valkey
  control_minio_edge
  control_web_edge
}

ff5() {
  local t
  local closed=(
    1.1.1.1:443 example.com:443 gateway.svp.svc.cluster.local:8080 user-service.svp.svc.cluster.local:9101
    video-service.svp.svc.cluster.local:9102 engagement-service.svp.svc.cluster.local:9103
    feed-service.svp.svc.cluster.local:9104 svp-pg-rw.svp-data.svc.cluster.local:5432
    valkey.svp-data.svc.cluster.local:6379 kubernetes.default.svc.cluster.local:443
  )
  local open=(
    minio.svp-data.svc.cluster.local:9000 redpanda.svp-data.svc.cluster.local:9092
    otel-collector.svp-obs.svc.cluster.local:4317
  )
  reach svp deploy/media-worker "${closed[@]}" "${open[@]}"
  for t in "${closed[@]}"; do expect_reach "$t" closed "FF-5: from media-worker"; done
  for t in "${open[@]}"; do expect_reach "$t" open "FF-5: from media-worker"; done
  control_readyz
  control_engagement
  control_healthz
  control_postgres
  control_valkey
  reach "$probe_ns" pod/probe kubernetes.default.svc.cluster.local:443
  expect_reach kubernetes.default.svc.cluster.local:443 open "control: from $probe_ns (no egress policy), the API server"
  info "FF-5: the internet has no control case: the drill tries the internet from media-worker only; example.com resolved there, so its failure is the connection"
}

# The Kafka checks run in the broker container as one user each: the password is the first line on stdin, read into
# RPK_PASS (rpk's own variable) and never on a command line; then "OP:ARG" per check, each answered by one line
# "OP:ARG rc=<exit status> code=<first Kafka error code or none> at=<partition@offset of a produced record or ->".
# produce writes one empty record with rpk's default, idempotent producer, which first asks for a producer id (granted
# with WRITE on any topic); produce1 the same with acks 1, which is not idempotent, so only the right to write the topic
# itself is asked; oversized one record of 1.6 MB (incompressible, no compression, the client's own limit raised so
# the broker decides); group describes a group; consume reads one record without a group.
# shellcheck disable=SC2016 # expanded by bash inside the container
kafka_ops='
IFS= read -r RPK_PASS
export RPK_PASS RPK_USER=$1
key=drill-threats-$2
shift 2
big=$(mktemp)
trap "rm -f \"$big\"" EXIT
for op in "$@"; do
  arg=${op#*:}
  case ${op%%:*} in
    produce) out=$(printf "\n" | timeout 20 rpk topic produce "$arg" -k "$key" -H svp-drill=threats 2>&1); rc=$? ;;
    produce1) out=$(printf "\n" | timeout 20 rpk topic produce "$arg" --acks 1 -k "$key" -H svp-drill=threats 2>&1); rc=$? ;;
    oversized)
      [ -s "$big" ] || { head -c 1200000 /dev/urandom | base64 -w0; echo; } >"$big"
      out=$(timeout 30 rpk topic produce "$arg" -k "$key" -z none --max-message-bytes 4000000 <"$big" 2>&1); rc=$? ;;
    group) out=$(timeout 20 rpk group describe "$arg" 2>&1); rc=$? ;;
    consume) out=$(timeout 20 rpk topic consume "$arg" -n 1 -o start 2>&1); rc=$? ;;
    *) out=; rc=99 ;;
  esac
  code=$(printf "%s\n" "$out" | grep -oE "[A-Z]+(_[A-Z]+)+" | head -n 1)
  at=$(printf "%s\n" "$out" | sed -n "s/^Produced to partition \([0-9]*\) at offset \([0-9]*\).*/\1@\2/p")
  echo "$op rc=$rc code=${code:-none} at=${at:--}"
done'

# kafka_check USER OP:ARG:WANT...: runs the operations as USER and checks each: WANT ok means it worked, otherwise
# that it failed with Kafka error code WANT.
kafka_check() {
  local user=$1 pw c op what got rc code at
  shift
  local ops=()
  for c in "$@"; do ops+=("${c%:*}"); done
  pw=$(kc -n svp-data get secret kafka-users -o json | jq -r --arg u "$user" '.data[$u] // empty | @base64d') ||
    fail "IN-4: read the password of $user from Secret svp-data/kafka-users"
  [[ -n $pw ]] || fail "IN-4: Secret svp-data/kafka-users has a password for $user"
  printf '%s\n' "$pw" | kc -n svp-data exec -i redpanda-0 -c redpanda -- bash -c "$kafka_ops" bash "$user" "$run_id" "${ops[@]}" \
    >"$work/kafka" || fail "IN-4: run the Kafka checks as $user in redpanda-0"
  pw=
  for c in "$@"; do
    op=${c%:*}
    case ${op%%:*} in
      produce) what="produce to ${op#*:} (idempotent)" ;;
      produce1) what="produce to ${op#*:} (acks 1, not idempotent)" ;;
      oversized) what="produce an oversized record to ${op#*:}" ;;
      group) what="describe group ${op#*:}" ;;
      consume) what="read ${op#*:} without a group" ;;
    esac
    read -r got rc code at <<<"$(awk -v o="$op" '$1 == o' "$work/kafka")"
    rc=${rc#rc=} code=${code#code=} at=${at#at=}
    case ${c##*:} in
      ok)
        if [[ ${op%%:*} == produce ]]; then
          [[ $got == "$op" && $rc == 0 && $at != - ]] &&
            ok "IN-4: $user may $what with WRITE on the topic only: record at partition@offset $at" ||
            miss "IN-4: $user may $what (rc '$rc', code '$code', record at '$at')"
        else
          [[ $got == "$op" && $rc == 0 ]] && ok "IN-4: $user may $what" || miss "IN-4: $user may $what (rc '$rc', code '$code')"
        fi
        ;;
      MESSAGE_TOO_LARGE)
        [[ $got == "$op" && $rc != 0 && $code == MESSAGE_TOO_LARGE ]] &&
          ok "IN-4: $user may write ${op#*:}: its oversized record passed the authorization and was refused for its size only (MESSAGE_TOO_LARGE), nothing written" ||
          miss "IN-4: $user's oversized record to ${op#*:} is refused for its size only, MESSAGE_TOO_LARGE (rc '$rc', code '$code')"
        ;;
      *)
        [[ $got == "$op" && $rc != 0 && $code == "${c##*:}" ]] && ok "IN-4: $user may not $what: $code" ||
          miss "IN-4: $user may not $what, refused with ${c##*:} (rc '$rc', code '$code')"
        ;;
    esac
  done
}

# topic_ends: "TOPIC SUM" of the high watermarks of the four topics the services consume; false when rpk fails or
# its table is not the expected one (last column HIGH-WATERMARK, a number on every partition row, at least one row),
# so a read that failed twice can never compare as "unchanged".
topic_ends() {
  local t out sum
  for t in user.follows.v1 video.lifecycle.v1 media.transcodes.v1 engagement.views.v1; do
    out=$(rpk topic describe "$t" -p) || return 1
    sum=$(awk 'NR == 1 { if ($NF != "HIGH-WATERMARK") bad = 1; next }
      $NF !~ /^[0-9]+$/ { bad = 1 } { s += $NF; n++ }
      END { if (!bad && n > 0) print s }' <<<"$out")
    [[ -n $sum ]] || return 1
    printf '%s %s\n' "$t" "$sum"
  done
}

in4_acl() {
  local before after p status
  before=$(topic_ends) || fail "IN-4: read the high watermarks of the consumed topics"
  # First: feed-service may read user.follows.v1 (so its metadata is visible) but not write it; the broker refusing
  # its oversized record as unauthorized shows it checks the right to write before the size, which is what makes
  # MESSAGE_TOO_LARGE for user-service below a proof of its right.
  kafka_check svp-feed-service oversized:user.follows.v1:TOPIC_AUTHORIZATION_FAILED produce:user.follows.v1.dlq:ok \
    produce:video.lifecycle.v1:TOPIC_AUTHORIZATION_FAILED group:feed-service:ok group:video-service:GROUP_AUTHORIZATION_FAILED
  kafka_check svp-user-service produce:video.lifecycle.v1:TOPIC_AUTHORIZATION_FAILED \
    oversized:user.follows.v1:MESSAGE_TOO_LARGE group:feed-service:GROUP_AUTHORIZATION_FAILED
  kafka_check svp-video-service produce:user.follows.v1:TOPIC_AUTHORIZATION_FAILED produce:media.transcodes.v1.dlq:ok \
    group:video-service:ok group:media-worker:GROUP_AUTHORIZATION_FAILED
  kafka_check svp-engagement-service produce:video.lifecycle.v1:TOPIC_AUTHORIZATION_FAILED \
    produce:engagement.views.v1.dlq:ok group:engagement-service:ok group:feed-service:GROUP_AUTHORIZATION_FAILED
  kafka_check svp-media-worker produce:video.lifecycle.v1:TOPIC_AUTHORIZATION_FAILED \
    produce:user.follows.v1:TOPIC_AUTHORIZATION_FAILED produce:video.lifecycle.v1.dlq:ok group:media-worker:ok \
    group:engagement-service:GROUP_AUTHORIZATION_FAILED consume:engagement.views.v1:TOPIC_AUTHORIZATION_FAILED
  # svp-keda may write no topic at all, so its idempotent producer gets no producer id (a cluster-level refusal); the
  # non-idempotent one shows the refusal on the topic itself.
  kafka_check svp-keda produce:video.lifecycle.v1:CLUSTER_AUTHORIZATION_FAILED \
    produce1:video.lifecycle.v1:TOPIC_AUTHORIZATION_FAILED group:media-worker:ok \
    group:feed-service:GROUP_AUTHORIZATION_FAILED consume:video.lifecycle.v1:TOPIC_AUTHORIZATION_FAILED
  if after=$(topic_ends); then
    [[ $after == "$before" ]] &&
      ok "IN-4: high watermarks of user.follows.v1, video.lifecycle.v1, media.transcodes.v1, engagement.views.v1 unchanged ($(tr '\n' ' ' <<<"$after")): no test record reached a consumed topic" ||
      miss "IN-4: high watermarks of the consumed topics unchanged (before: $(tr '\n' ' ' <<<"$before"), after: $(tr '\n' ' ' <<<"$after"))"
  else
    miss "IN-4: read the high watermarks of the consumed topics after the checks (rpk topic describe failed or gave no partition)"
  fi

  for p in /v1/node_config /v1/cluster_config /v1/security/users /v1/brokers /public_metrics; do
    status=$(kc -n svp-data exec redpanda-0 -c redpanda -- curl -s -o /dev/null --max-time 5 -w '%{http_code}' \
      "http://redpanda-0.redpanda.svp-data.svc.cluster.local.:9644$p" || true)
    if [[ $p == /public_metrics ]]; then
      [[ $status == 200 ]] && ok "IN-4: Admin API $p without credentials: 200 (the Collector's scrape)" ||
        miss "IN-4: Admin API $p without credentials is 200 (status $status)"
    else
      [[ $status == 401 || $status == 403 ]] && ok "IN-4: Admin API $p without credentials: $status" ||
        miss "IN-4: Admin API $p without credentials is 401 or 403 (status $status)"
    fi
  done
  [[ $(rpk cluster config get admin_api_require_auth 2>/dev/null) == true ]] &&
    control "rpk with the broker's own login (svp-admin) reads admin_api_require_auth through the Admin API: true" ||
    miss "control: rpk as svp-admin reads admin_api_require_auth = true"
}

in9() {
  local primary rules out last
  primary=$(kc -n svp-data get cluster.postgresql.cnpg.io svp-pg -o jsonpath='{.status.currentPrimary}')
  [[ -n $primary ]] || fail "IN-9: read the primary of Cluster svp-data/svp-pg"
  # Peer login on the pod's socket, as the image's postgres user: the one way in without a password, by design.
  rules=$(kc -n svp-data exec "$primary" -c postgres -- psql -X -A -t -F ' ' -U postgres -d postgres -c \
    "select line_number, type, array_to_string(database, ','), array_to_string(user_name, ','), coalesce(address, '-'), auth_method from pg_hba_file_rules order by line_number") ||
    fail "IN-9: read pg_hba_file_rules on $primary"
  echo "$rules" | sed 's/^/      pg_hba line /'
  [[ -n $rules ]] && ! awk '$NF == "trust"' <<<"$rules" | grep -q . &&
    ok "IN-9: no pg_hba rule of $primary is trust" || miss "IN-9: no pg_hba rule of $primary is trust"
  awk '$2 ~ /^host/ && $NF != "scram-sha-256" && $NF != "cert"' <<<"$rules" | grep -q . &&
    miss "IN-9: every TCP (host*) rule of $primary is scram-sha-256 or cert" ||
    ok "IN-9: every TCP (host*) rule of $primary is scram-sha-256 or cert"
  # The rules are ordered by line: the last one is CloudNativePG's catch-all, to which the project adds nothing.
  last=$(tail -n 1 <<<"$rules" | cut -d ' ' -f 2-)
  [[ $last == "host all all all scram-sha-256" ]] &&
    ok "IN-9: the last pg_hba rule of $primary is host all all all scram-sha-256 (CloudNativePG's default, nothing added after it)" ||
    miss "IN-9: the last pg_hba rule of $primary is host all all all scram-sha-256 (got: ${last:-no rule})"

  # From GlitchTip's pod, which the policy lets in to 5432: libpq through psycopg, no password file, no password.
  out=$(kc -n svp-obs exec deploy/glitchtip -- python -c '
import secrets, psycopg
cases = [("postgres", "require", ""), ("postgres", "disable", ""), ("svp_user_app", "require", ""),
         ("postgres", "require", secrets.token_hex(16))]
for user, ssl, pw in cases:
    try:
        psycopg.connect(f"host=svp-pg-rw.svp-data.svc.cluster.local port=5432 dbname=postgres user={user} "
                        f"sslmode={ssl} connect_timeout=5 passfile=/nonexistent", password=pw).close()
        print(user, ssl, "nopassword" if not pw else "wrongpassword", "CONNECTED")
    except psycopg.OperationalError as e:
        msg = str(e)
        why = "no-password-supplied" if "no password supplied" in msg else \
              "password-authentication-failed" if "password authentication failed" in msg else "other"
        print(user, ssl, "nopassword" if not pw else "wrongpassword", why)
') || fail "IN-9: run the login attempts in GlitchTip's pod"
  while read -r user ssl how why; do
    if [[ $how == nopassword ]]; then
      [[ $why == no-password-supplied ]] && ok "IN-9: from GlitchTip's pod, $user over TCP (sslmode=$ssl) without a password: refused, the server asks for one" ||
        miss "IN-9: from GlitchTip's pod, $user over TCP (sslmode=$ssl) without a password is refused (got $why)"
    else
      [[ $why == password-authentication-failed ]] && control "from GlitchTip's pod, $user with a wrong password: password authentication failed (the server checks it)" ||
        miss "control: from GlitchTip's pod, $user with a wrong password fails authentication (got $why)"
    fi
  done <<<"$out"

  out=$(kc -n svp-data exec "$primary" -c postgres -- env -u PGPASSWORD PGPASSFILE=/nonexistent \
    psql -X -w "host=127.0.0.1 port=5432 user=postgres dbname=postgres sslmode=disable" -c 'select 1' 2>&1 || true)
  grep -q 'no password supplied' <<<"$out" &&
    ok "IN-9: inside $primary, postgres over TCP to 127.0.0.1 without a password: refused (no trust on loopback)" ||
    miss "IN-9: inside $primary, postgres over TCP to 127.0.0.1 without a password is refused (got: $(head -n 1 <<<"$out"))"
}

# The rules of FF-3/FF-4 for every container (init and ephemeral ones too) of the pods in the input list: one line
# "POD/CONTAINER ok|<broken rules> requests=... limits=...". A container's runAsNonRoot and seccomp profile override
# the pod's, so the pod's apply only where the container's are unset (null, never false). $tokens (--argjson) names
# the Secrets of type kubernetes.io/service-account-token: even with automountServiceAccountToken false, a token can
# reach a container at any path through a volume of such a Secret, of a projected serviceAccountToken or of a
# projected volume with such a Secret as a source, and through env or envFrom naming such a Secret.
# shellcheck disable=SC2016 # jq program
pod_rules='
def token_secret: . as $n | $n != null and any($tokens[]; . == $n);
.items[] | .metadata.name as $pod | .spec as $s | ($s.securityContext // {}) as $ps |
[$s.volumes[]? | select(any(.projected.sources[]?; .serviceAccountToken != null or (.secret.name | token_secret))
  or (.secret.secretName | token_secret)) | .name] as $tokenvols |
(($s.initContainers // []) + ($s.containers // []) + ($s.ephemeralContainers // []))[] |
. as $c | ($c.securityContext // {}) as $cs |
[
  (if ($c.resources.requests.cpu and $c.resources.requests.memory and $c.resources.limits.cpu and $c.resources.limits.memory) then empty else "resources" end),
  (if (if $cs.runAsNonRoot == null then $ps.runAsNonRoot else $cs.runAsNonRoot end) == true then empty else "runAsNonRoot" end),
  (if $cs.readOnlyRootFilesystem == true then empty else "readOnlyRootFilesystem" end),
  (if (($cs.capabilities.drop // []) | index("ALL")) then empty else "drop-ALL" end),
  (if (($cs.capabilities.add // []) | length) == 0 then empty else "capabilities-added" end),
  (if $cs.allowPrivilegeEscalation == false then empty else "allowPrivilegeEscalation" end),
  (if ($cs.seccompProfile.type // $ps.seccompProfile.type) == "RuntimeDefault" then empty else "seccomp" end),
  (if $cs.privileged == true then "privileged" else empty end),
  (if $s.automountServiceAccountToken == false then empty else "automountServiceAccountToken" end),
  (if ([$c.volumeMounts[]? | select((.mountPath | startswith("/var/run/secrets/kubernetes.io")) or (.name as $v | any($tokenvols[]; . == $v)))] | length) == 0 then empty else "token-mounted" end),
  (if ([($c.env[]? | .valueFrom.secretKeyRef.name), ($c.envFrom[]? | .secretRef.name)] | any(.[]; token_secret)) then "token-env" else empty end),
  (if ($s.hostNetwork or $s.hostPID or $s.hostIPC) then "host-namespaces" else empty end),
  (if ([$s.volumes[]? | select(.hostPath)] | length) == 0 then empty else "hostPath" end)
] as $bad |
"\($pod)/\($c.name) \(if ($bad | length) == 0 then "ok" else ($bad | join(",")) end) requests=\($c.resources.requests.cpu)/\($c.resources.requests.memory) limits=\($c.resources.limits.cpu)/\($c.resources.limits.memory)"'

# psa_pod USER [NAMESPACE]: a pod for NAMESPACE (default svp) in the image media-worker runs, restricted in every
# respect but running as USER.
psa_pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: drill-threats-psa
  namespace: ${2:-svp}
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: $([[ $1 == 0 ]] && echo false || echo true)
    runAsUser: $1
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: $worker_image
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
EOF
}

# privileged_pod NAMESPACE: a pod for NAMESPACE that would take its node over: privileged, root, the node's / mounted
# as a hostPath volume. Only ever sent as a server-side dry run.
privileged_pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: drill-threats-privileged
  namespace: $1
spec:
  automountServiceAccountToken: false
  containers:
    - name: c
      image: $worker_image
      securityContext:
        privileged: true
        runAsUser: 0
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
EOF
}

ff3() {
  local line n bad ns label out want node pids tokens pod
  # Names only: no Secret value is printed or kept.
  tokens=$(kc -n svp get secrets --field-selector type=kubernetes.io/service-account-token -o json | jq -c '[.items[].metadata.name]') ||
    fail "FF-4: list the Secrets of type service-account-token in svp"
  kc -n svp get pods -o json | jq -r --argjson tokens "$tokens" "$pod_rules" >"$work/pods" || fail "FF-3/FF-4: read the pods of svp"
  n=$(wc -l <"$work/pods" | tr -d ' ')
  ((n > 0)) || miss "FF-3/FF-4: namespace svp has pods to check"
  while read -r line; do
    set -- $line
    [[ $2 == ok ]] && ok "FF-3/FF-4: $1: $3 $4" || miss "FF-3/FF-4: $1 breaks: $2"
  done <"$work/pods"
  # The web client's pods (a Rollout's, beside the six services') are among those checked.
  web_pods >"$work/web-pods" || miss "FF-3/FF-4: list the web client's pods ($web_selector)"
  [[ -s $work/web-pods ]] || miss "FF-3/FF-4: namespace svp has running pods of the web client ($web_selector)"
  while read -r pod _; do
    out=$(awk -v p="$pod/" 'index($1, p) == 1 { sub(p, "", $1); printf "%s ", $1 }' "$work/pods")
    [[ -n $out ]] && ok "FF-3/FF-4: the checks above cover web pod $pod (containers: ${out% })" ||
      miss "FF-3/FF-4: web pod $pod is among the pods checked"
  done <"$work/web-pods"
  # Controls: the same rules on a pod that sets none of them flag each one; on a pod restricted in every respect but
  # six containers (one sets runAsNonRoot false over the pod's true; three mount a token at a path of their own, from a
  # projected serviceAccountToken, from a Secret of type service-account-token and from that Secret as a source of a
  # projected volume; two read that Secret through env and envFrom) they flag exactly those, and pass a seventh that
  # mounts an ordinary Secret and reads it through envFrom, as the services do.
  bad=$(jq -n '{items: [{metadata: {name: "bare"}, spec: {containers: [{name: "c", volumeMounts: [{mountPath: "/var/run/secrets/kubernetes.io/serviceaccount"}]}], hostNetwork: true, volumes: [{hostPath: {path: "/"}}]}}]}' |
    jq -r --argjson tokens '[]' "$pod_rules" | awk '{ print $2 }')
  [[ $bad == resources,runAsNonRoot,readOnlyRootFilesystem,drop-ALL,allowPrivilegeEscalation,seccomp,automountServiceAccountToken,token-mounted,host-namespaces,hostPath ]] &&
    control "the same rules on a bare pod flag all of them: $bad" || miss "control: the rules flag every rule on a bare pod (got $bad)"
  bad=$(jq -n '
    {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}} as $sc |
    {resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {cpu: "100m", memory: "32Mi"}}, securityContext: $sc} as $c |
    {items: [{metadata: {name: "override"}, spec: {
      automountServiceAccountToken: false,
      securityContext: {runAsNonRoot: true, seccompProfile: {type: "RuntimeDefault"}},
      volumes: [{name: "tok", projected: {sources: [{serviceAccountToken: {path: "token"}}]}},
        {name: "legacy", secret: {secretName: "drill-legacy-token"}},
        {name: "bundle", projected: {sources: [{configMap: {name: "drill-ca"}}, {secret: {name: "drill-legacy-token"}}]}},
        {name: "env", secret: {secretName: "drill-env"}}],
      containers: [
        ($c + {name: "root", securityContext: ($sc + {runAsNonRoot: false})}),
        ($c + {name: "projected", volumeMounts: [{name: "tok", mountPath: "/var/run/svp-token"}]}),
        ($c + {name: "legacy", volumeMounts: [{name: "legacy", mountPath: "/tok"}]}),
        ($c + {name: "bundle", volumeMounts: [{name: "bundle", mountPath: "/x"}]}),
        ($c + {name: "env", env: [{name: "TZ", value: "UTC"}, {name: "T", valueFrom: {secretKeyRef: {name: "drill-legacy-token", key: "token"}}}]}),
        ($c + {name: "envfrom", envFrom: [{secretRef: {name: "drill-legacy-token"}}]}),
        ($c + {name: "plain", volumeMounts: [{name: "env", mountPath: "/env"}], envFrom: [{secretRef: {name: "drill-env"}}]})]}}]}' |
    jq -r --argjson tokens '["drill-legacy-token"]' "$pod_rules" | awk '{ printf "%s %s;", $1, $2 }')
  [[ $bad == "override/root runAsNonRoot;override/projected token-mounted;override/legacy token-mounted;override/bundle token-mounted;override/env token-env;override/envfrom token-env;override/plain ok;" ]] &&
    control "the same rules on a restricted pod flag a container's runAsNonRoot false over the pod's true, a token mounted at /var/run/svp-token (projected serviceAccountToken), /tok (Secret) and /x (Secret in a projected volume), the token Secret in env and envFrom, and pass an ordinary Secret as a volume and envFrom: $bad" ||
    miss "control: the rules flag a container's runAsNonRoot false and every way a token reaches a container outside /var/run/secrets, and pass an ordinary Secret (got $bad)"

  for ns in svp svp-data svp-obs svp-edge argo-rollouts; do
    label=$(kc get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce} {.metadata.labels.pod-security\.kubernetes\.io/enforce-version}')
    [[ $label == "restricted $psa_version" ]] && ok "FF-4: namespace $ns enforces PSA restricted $psa_version" ||
      miss "FF-4: namespace $ns enforces PSA restricted $psa_version (got '$label')"
  done
  out=$(psa_pod 0 | kc create --dry-run=server -f - 2>&1 || true)
  grep -qF "violates PodSecurity \"restricted:$psa_version\"" <<<"$out" &&
    ok "FF-4: a pod running as root in svp is Forbidden by PSA (server-side dry run): $(grep -o 'runAsNonRoot[^,;]*' <<<"$out" | head -n 1)" ||
    miss "FF-4: a pod running as root in svp is Forbidden by PSA restricted:$psa_version (got: $(head -n 1 <<<"$out"))"
  out=$(psa_pod 65532 | kc create --dry-run=server -f - 2>&1 || true)
  grep -q 'created (server dry run)' <<<"$out" && control "the same pod as uid 65532 is admitted in svp (server-side dry run)" ||
    miss "control: the restricted pod is admitted in svp (got: $(head -n 1 <<<"$out"))"

  want=$(sed -n 's/.*--kubelet-arg=pod-max-pids=\([0-9]*\).*/\1/p' "$repo_root/deploy/k8s/k3d.yaml")
  [[ -n $want ]] || miss "FF-3: deploy/k8s/k3d.yaml sets --kubelet-arg=pod-max-pids"
  for node in $(kc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    pids=$(kc get --raw "/api/v1/nodes/$node/proxy/configz" | jq -r '.kubeletconfig.podPidsLimit // empty')
    [[ -n $want && $pids == "$want" ]] && ok "FF-3: kubelet of $node: podPidsLimit $pids (pod-max-pids of deploy/k8s/k3d.yaml; the kubelet's default is -1, unlimited)" ||
      miss "FF-3: kubelet of $node has podPidsLimit $want (got '$pids')"
  done
}

# rules_reads: of a SelfSubjectRulesReview (its JSON on stdin), the rules that let its subject read secrets or pods:
# get, list or watch (a watch streams every object, as a list does), in the core group or every group, on all objects
# or on named ones (resourceNames); one "RESOURCE[/NAMES]:VERBS" per rule and resource, sorted and joined by commas,
# "none" when there is none, "incomplete: ..." when the server could not list every rule (which proves nothing),
# "error: ..." when the JSON is no review status at all: an empty rule list read from it would pass as "none".
# shellcheck disable=SC2016 # jq program
rules_reads='.status as $s |
if ($s | type) != "object" or ($s.resourceRules | type) != "array" then "error: the response holds no rules review status"
elif ($s.incomplete // false) or (($s.evaluationError // "") != "") then "incomplete: \($s.evaluationError // "")"
else
  [$s.resourceRules[]? | select(any(.apiGroups[]?; . == "" or . == "*")) as $r |
    [$r.verbs[]? | select(. == "get" or . == "list" or . == "watch" or . == "*")] as $v |
    select($v | length > 0) |
    $r.resources[]? | select(. == "secrets" or . == "pods" or . == "*") |
    "\(.)\(if ($r.resourceNames // []) | length > 0 then "/" + ($r.resourceNames | join("|")) else "" end):\($v | join("|"))"]
  | unique | if length == 0 then "none" else join(",") end
end'

# rules_review NAMESPACE/SA NS: the SelfSubjectRulesReview of ServiceAccount NAMESPACE/SA in namespace NS, made as that
# ServiceAccount (impersonation, as kubectl auth can-i --as), printed by rules_reads. A review lists the rules of the
# Roles bound in NS and of every ClusterRole bound, the way the authorizer applies them.
# --validate=false: kubectl's client-side schema check lists the cluster's CRDs, and it does so as the impersonated
# ServiceAccount, which may not list them; the check then fails before the review is sent. The object is fixed here and
# the API server still decodes it; a failed create fails the pipeline (pipefail), so the caller reports an error.
rules_review() {
  printf '{"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectRulesReview","spec":{"namespace":"%s"}}' "$2" |
    kc create -f - -o json --validate=false --as="system:serviceaccount:${1%/*}:${1#*/}" | jq -r "$rules_reads"
}

rbac() {
  local sa ns r v scope out bad=0 n=0
  local sas nss
  sas=$(kc -n svp get serviceaccounts -o jsonpath='{.items[*].metadata.name}')
  [[ -n $sas ]] || fail "RBAC: list the ServiceAccounts of svp"
  # Every namespace the cluster has now, not a fixed list: a RoleBinding in any of them, a platform namespace's
  # included, can grant a ServiceAccount of svp access there, and kubectl auth can-i -A answers only for a right that
  # holds in every namespace at once.
  nss=$(kc get namespaces -o jsonpath='{.items[*].metadata.name}')
  [[ -n $nss ]] || fail "RBAC: list the namespaces of the cluster"
  # One background job per ServiceAccount: 5 calls per namespace, a tenth of a second per call. The rules review
  # catches what can-i asked without a name answers no to: a Role that grants get on named Secrets or pods only, and
  # watch.
  for sa in $sas; do
    (
      for ns in $nss -A; do
        if [[ $ns == -A ]]; then scope=(-A); else scope=(-n "$ns"); fi
        for r in secrets pods; do
          for v in get list; do
            out=$(kc auth can-i "$v" "$r" "${scope[@]}" --as="system:serviceaccount:svp:$sa" 2>&1 || true)
            echo "$sa $ns $v $r $out"
          done
        done
        if [[ $ns != -A ]]; then
          out=$(rules_review "svp/$sa" "$ns" 2>"$work/rbac-$sa.err") ||
            out="error: the rules review failed: $(head -n 1 "$work/rbac-$sa.err")"
          echo "$sa $ns rules - ${out:-error: empty rules review}"
        fi
      done
    ) >"$work/rbac-$sa" &
  done
  wait
  for sa in $sas; do
    while read -r _ ns v r out; do
      n=$((n + 1))
      if [[ $v == rules ]]; then
        [[ $out == none ]] || {
          miss "RBAC: no rule lets ServiceAccount svp/$sa get, list or watch secrets or pods in namespace $ns, by name or not (got: $out)"
          bad=$((bad + 1))
        }
      else
        [[ $out == no ]] || {
          miss "RBAC: ServiceAccount svp/$sa may not $v $r in ${ns/-A/all namespaces} (got '$out')"
          bad=$((bad + 1))
        }
      fi
    done <"$work/rbac-$sa"
  done
  ((bad == 0)) && ok "RBAC: $n checks, every ServiceAccount of svp ($sas) in each namespace of the cluster ($nss) and cluster-wide: can-i says no to get and list of secrets and pods, and no rule lets it get, list or watch them, by name or not"
  # Controls: the rule check flags exactly the named, the watch and the wildcard rules of a sample review; on the
  # Argo Rollouts controller's own review in svp it finds the right to list pods, which can-i answers yes to as well.
  out=$(jq -n '{status: {incomplete: false, resourceRules: [
      {verbs: ["get"], apiGroups: [""], resources: ["secrets"], resourceNames: ["drill-tls"]},
      {verbs: ["watch"], apiGroups: [""], resources: ["pods"]},
      {verbs: ["*"], apiGroups: ["*"], resources: ["*"]},
      {verbs: ["get", "list"], apiGroups: [""], resources: ["pods/log", "configmaps"]},
      {verbs: ["create", "delete"], apiGroups: [""], resources: ["secrets"]},
      {verbs: ["get"], apiGroups: ["apps"], resources: ["deployments"]}]}}' | jq -r "$rules_reads")
  [[ $out == '*:*,pods:watch,secrets/drill-tls:get' ]] &&
    control "the rule check on a sample review flags its named, watch and wildcard rules and none of pods/log, configmaps, create on secrets or apps: $out" ||
    miss "control: the rule check flags exactly the named, watch and wildcard rules of a sample review (got: $out)"
  out=$(kc auth can-i list pods -n svp --as=system:serviceaccount:argo-rollouts:argo-rollouts 2>&1 || true)
  r=$(rules_review argo-rollouts/argo-rollouts svp 2>&1) || r="error: $(head -n 1 <<<"$r")"
  [[ $out == yes && $r == *pods:*list* ]] &&
    control "the Argo Rollouts controller may list pods in svp: can-i yes, its rules review $r" ||
    miss "control: the Argo Rollouts controller may list pods in svp: can-i yes and its rules review has pods with list (can-i '$out', review: $r)"

  # Operators outside svp (docs/adr/0014-kubernetes-local-stage4.md): the rights narrowed in their values, and the
  # exceptions that stay.
  local cnpg="cnpg-system svp-data" eg="envoy-gateway-system svp svp-data svp-edge"
  operator_scope cnpg-system/cloudnative-pg "$cnpg" "get secrets" get secrets
  operator_scope cnpg-system/cloudnative-pg "$cnpg" "list secrets" list secrets
  # In cnpg-system, beside the Barman Cloud plugin whose ServiceAccount reads every Secret of the cluster, the
  # operator reads, and writes only its PKI Secrets, events and Lease: nothing that runs code as that ServiceAccount.
  operator_scope cnpg-system/cloudnative-pg svp-data "create pods" create pods
  operator_scope cnpg-system/cloudnative-pg svp-data "exec into pods" create pods --subresource=exec
  operator_scope cnpg-system/cloudnative-pg svp-data "patch deployments" patch deployments
  operator_scope cnpg-system/cloudnative-pg svp-data "create serviceaccounts" create serviceaccounts
  operator_scope cnpg-system/cloudnative-pg svp-data "delete secrets" delete secrets
  operator_scope cnpg-system/cloudnative-pg "" "create serviceaccount tokens" create serviceaccounts --subresource=token
  cnpg_secrets
  operator_scope envoy-gateway-system/envoy-gateway "$eg" "get secrets" get secrets
  operator_scope envoy-gateway-system/envoy-gateway "$eg" "list secrets" list secrets
  operator_scope envoy-gateway-system/envoy-gateway "" "patch pods" patch pods
  # Kyverno (docs/adr/0015-cicd-devsecops-stage5.md, section 8): its own TLS Secrets and its lease, nothing else.
  for sa in kyverno-admission-controller kyverno-reports-controller; do
    operator_scope "kyverno/$sa" kyverno "get secrets" get secrets
    operator_scope "kyverno/$sa" kyverno "list secrets" list secrets
    operator_scope "kyverno/$sa" "" "create pods" create pods
  done
  # Webhook configurations are cluster-scoped: asked with -A, kubectl prints no warning that they have no namespace.
  # Writing one would let the operator send itself every Secret written in the cluster; cainjector writes the CA of its
  # two (deploy/k8s/values/cloudnative-pg.yaml).
  for r in mutatingwebhookconfigurations validatingwebhookconfigurations; do
    for v in create update patch; do
      out=$(kc auth can-i "$v" "$r.admissionregistration.k8s.io" -A \
        --as=system:serviceaccount:cnpg-system:cloudnative-pg 2>&1 || true)
      [[ $out == no ]] && ok "RBAC: cnpg-system/cloudnative-pg may not $v $r" ||
        miss "RBAC: cnpg-system/cloudnative-pg may not $v $r (got '$out')"
    done
  done
  info "RBAC exception: Envoy Gateway reads the Secrets of svp and svp-data, which it watches for routes api and s3 (its Secret cache covers every watched namespace; deploy/k8s/values/envoy-gateway.yaml)"
  info "RBAC exception: cert-manager's controller and cainjector read Secrets in every namespace, cainjector patches every webhook configuration, the controller creates pods in every namespace (Certificates in cert-manager, svp-edge, keda and cnpg-system, ClusterIssuers svp-selfsigned and svp-ca; deploy/k8s/values/cert-manager.yaml); its pods are held to PSA restricted everywhere but kube-system (PSA-platform)"
  info "RBAC exception: Argo CD's application controller and server (GitOps path) hold rights on every resource of the cluster, Secrets included: they apply every chart (ADR-0014 section 12)"
  info "RBAC exception: the Barman Cloud plugin (cnpg-system/plugin-barman-cloud, backups of Postgres svp-pg) reads, creates and deletes the Secrets of every namespace, the JWT signing key of svp included, and creates Roles and RoleBindings everywhere: its manager caches the whole cluster with no flag to narrow it, so a Role per namespace as for CloudNativePG would leave it failing on permissions (threat model BAK-1, accepted for the lab; deploy/k8s/values/plugin-barman-cloud.yaml); the CloudNativePG operator beside it in cnpg-system may neither run code as its ServiceAccount nor get it a token (checked above)"
  info "RBAC exception: Kyverno's admission controller creates, patches and deletes every webhook configuration and validating admission policy of the cluster: it registers the webhooks of its policies itself (a taken-over controller could send itself any request, or drop the image policy's webhook); its reports controller reads the pods of every namespace (what the policy matches; the chart's view binding is off, deploy/k8s/values/kyverno.yaml)"
}

# cnpg_secrets: the CloudNativePG operator may create Secrets in cnpg-system (its CA, cnpg-ca-secret, made at start),
# and RBAC cannot narrow create by name, so ValidatingAdmissionPolicy svp-cnpg-operator-secrets (chart svp-cluster,
# templates/cnpg-rbac.yaml) keeps its writes there to cnpg-ca-secret and cnpg-webhook-cert. Server-side dry runs, as
# the operator's ServiceAccount but for one control: nothing is written.
cnpg_secrets() {
  local as=--as=system:serviceaccount:cnpg-system:cloudnative-pg vap="ValidatingAdmissionPolicy 'svp-cnpg-operator-secrets'"
  local name type what out tls
  while read -r name type what; do
    out=$(cnpg_secret "$name" "$type" | kc create --dry-run=server -f - "$as" 2>&1 || true)
    [[ $out == *"$vap"*denied* ]] &&
      ok "RBAC: cnpg-system/cloudnative-pg may not create $what in cnpg-system (refused by $vap)" ||
      miss "RBAC: cnpg-system/cloudnative-pg may not create $what in cnpg-system, refused by $vap (got: $(head -n 1 <<<"$out"))"
  done <<'CASES'
drill-plugin-token kubernetes.io/service-account-token a token Secret for ServiceAccount plugin-barman-cloud
cnpg-ca-secret kubernetes.io/service-account-token that token Secret named cnpg-ca-secret
drill-opaque Opaque an Opaque Secret of a name other than cnpg-ca-secret
CASES
  out=$(cnpg_secret cnpg-ca-secret Opaque | kc create --dry-run=server -f - "$as" 2>&1 || true)
  [[ ($out == *AlreadyExists* || $out == *'already exists'*) && $out != *"$vap"* ]] &&
    control "as the operator, an Opaque cnpg-ca-secret passes $vap and is refused only as AlreadyExists" ||
    miss "control: as the operator, an Opaque cnpg-ca-secret passes $vap and is AlreadyExists (got: $(head -n 1 <<<"$out"))"
  out=$(cnpg_secret drill-plugin-token kubernetes.io/service-account-token | kc create --dry-run=server -f - 2>&1 || true)
  [[ $out == *'created (server dry run)'* ]] &&
    control "as the drill's admin, the same token Secret is admitted in cnpg-system: the policy holds the operator only" ||
    miss "control: as the drill's admin, the token Secret is admitted in cnpg-system (got: $(head -n 1 <<<"$out"))"
  tls=$(kc -n cnpg-system get secrets --field-selector type=kubernetes.io/tls -o name |
    grep -vx 'secret/cnpg-webhook-cert' | head -n 1 || true)
  if [[ -z $tls ]]; then
    miss "RBAC: cnpg-system holds a TLS Secret other than cnpg-webhook-cert (the Barman Cloud plugin's) to update as the operator"
  else
    out=$(kc -n cnpg-system label "$tls" svp-drill=threats --dry-run=server "$as" 2>&1 || true)
    [[ $out == *"$vap"*denied* ]] &&
      ok "RBAC: cnpg-system/cloudnative-pg may not update $tls in cnpg-system (refused by $vap)" ||
      miss "RBAC: cnpg-system/cloudnative-pg may not update $tls in cnpg-system, refused by $vap (got: $(head -n 1 <<<"$out"))"
  fi
  out=$(kc -n cnpg-system label secret/cnpg-webhook-cert svp-drill=threats --dry-run=server "$as" 2>&1 || true)
  [[ $out == *'labeled (server dry run)'* ]] &&
    control "as the operator, an update of cnpg-webhook-cert passes $vap" ||
    miss "control: as the operator, an update of cnpg-webhook-cert passes $vap (got: $(head -n 1 <<<"$out"))"
}

# cnpg_secret NAME TYPE: Secret NAME of type TYPE in cnpg-system naming ServiceAccount plugin-barman-cloud, as JSON.
cnpg_secret() {
  jq -n --arg name "$1" --arg type "$2" '{apiVersion: "v1", kind: "Secret", type: $type, metadata: {name: $name,
    namespace: "cnpg-system", annotations: {"kubernetes.io/service-account.name": "plugin-barman-cloud"}}}'
}

# operator_scope NAMESPACE/SA ALLOWED LABEL CAN-I-ARGS...: kubectl auth can-i CAN-I-ARGS as ServiceAccount
# NAMESPACE/SA in each namespace of the cluster ($nss of rbac) and cluster-wide (-A). Passes when the answer is yes in
# every namespace of ALLOWED (space-separated) that exists and no in every other one and cluster-wide; LABEL names the
# right in the message.
operator_scope() {
  local sa=$1 want=$2 allowed=" $2 " label=$3 ns scope out yes= bad=
  shift 3
  for ns in $nss -A; do
    if [[ $ns == -A ]]; then scope=(-A); else scope=(-n "$ns"); fi
    out=$(kc auth can-i "$@" "${scope[@]}" --as="system:serviceaccount:${sa%/*}:${sa#*/}" 2>&1 || true)
    if [[ $ns != -A && $allowed == *" $ns "* ]]; then
      if [[ $out == yes ]]; then yes+=" $ns"; else bad+=" $ns:'$out'"; fi
    elif [[ $out != no ]]; then
      bad+=" ${ns/-A/all namespaces}:'$out'"
    fi
  done
  if [[ -n $bad ]]; then
    miss "RBAC: $sa may $label ${want:+in $want only, }nowhere ${want:+else }and not cluster-wide (got:$bad)"
  elif [[ -n $want ]]; then
    ok "RBAC: $sa may $label in$yes only, in no other namespace and not cluster-wide"
  else
    ok "RBAC: $sa may $label in no namespace and not cluster-wide"
  fi
}

# bak1_s3 CONFIG PATH: GET PATH of MinIO through Envoy, signed with AWS Signature V4 (MinIO's region us-east-1) as the
# user whose login the private curl config CONFIG holds; prints "STATUS CODE", CODE the S3 error code of the answer
# ("-" when it has none). The body stays in $work.
bak1_s3() {
  local status code
  : >"$work/bak1.out"
  status=$(curl -s --max-time 10 -o "$work/bak1.out" -w '%{http_code}' -K "$1" --aws-sigv4 aws:amz:us-east-1:s3 \
    "$s3_origin$2" || true)
  code=$(sed -n 's:.*<Code>\([A-Za-z]*\)</Code>.*:\1:p' "$work/bak1.out" | sed -n 1p)
  echo "$status ${code:--}"
}

# bak1_expect CONFIG USER PATH WANT WHAT: one request of bak1_s3 whose answer must be WANT; a refusal (403 AccessDenied)
# is a check of BAK-1, anything else a control.
bak1_expect() {
  local got
  got=$(bak1_s3 "$1" "$3")
  if [[ $4 == "403 AccessDenied" ]]; then
    [[ $got == "$4" ]] && ok "BAK-1: $2 $5 GET $3: $got" || miss "BAK-1: $2 $5 GET $3 is $4 (got $got)"
  else
    [[ $got == "$4" ]] && control "$2 $5 GET $3: $got" || miss "control: $2 $5 GET $3 is $4 (got $got)"
  fi
}

# bak1: the MinIO user of the backups of Postgres reads bucket pg-backups only, and no service's user reads that bucket
# (threat model BAK-1).
bak1() {
  local obj=drill-threats-$run_id user
  # The logins go to curl in private config files of $work, never on a command line, and are deleted at the end.
  kc -n svp-data get secret pg-backup-s3 -o json |
    jq -r '"user = \(((.data.ACCESS_KEY_ID | @base64d) + ":" + (.data.ACCESS_SECRET_KEY | @base64d)) | @json)"' \
      >"$work/bak1-svp-pg-backup.curl" || fail "BAK-1: read the login of svp-pg-backup from Secret svp-data/pg-backup-s3"
  kc -n svp-data get secret minio-users -o json | jq -r '
    "user = \(("svp-video-service:" + (.data.SVP_VIDEO_S3_SECRET_KEY | @base64d)) | @json)"' \
    >"$work/bak1-svp-video-service.curl" || fail "BAK-1: read the login of svp-video-service from Secret svp-data/minio-users"
  kc -n svp-data get secret minio-users -o json | jq -r '
    "user = \(("svp-media-worker:" + (.data.SVP_MEDIA_WORKER_S3_SECRET_KEY | @base64d)) | @json)"' \
    >"$work/bak1-svp-media-worker.curl" || fail "BAK-1: read the login of svp-media-worker from Secret svp-data/minio-users"

  user=svp-pg-backup
  bak1_expect "$work/bak1-$user.curl" "$user" "/pg-backups?list-type=2&max-keys=1" "200 -" "lists its bucket"
  bak1_expect "$work/bak1-$user.curl" "$user" "/pg-backups/$obj" "404 NoSuchKey" "reads its bucket"
  bak1_expect "$work/bak1-$user.curl" "$user" "/uploads?list-type=2&max-keys=1" "403 AccessDenied" "lists no bucket of the services:"
  bak1_expect "$work/bak1-$user.curl" "$user" "/uploads/uploads/$obj" "403 AccessDenied" "reads no bucket of the services:"
  bak1_expect "$work/bak1-$user.curl" "$user" "/media?list-type=2&max-keys=1" "403 AccessDenied" "lists no bucket of the services:"
  bak1_expect "$work/bak1-$user.curl" "$user" "/media/media/$obj" "403 AccessDenied" "reads no bucket of the services:"
  for user in svp-video-service svp-media-worker; do
    bak1_expect "$work/bak1-$user.curl" "$user" "/uploads/uploads/$obj" "404 NoSuchKey" "reads its own prefix"
    bak1_expect "$work/bak1-$user.curl" "$user" "/pg-backups?list-type=2&max-keys=1" "403 AccessDenied" "lists no backup:"
    bak1_expect "$work/bak1-$user.curl" "$user" "/pg-backups/$obj" "403 AccessDenied" "reads no backup:"
  done
  rm -f "$work"/bak1-*.curl
}

ops1() {
  local p status
  for p in /debug/pprof/ /debug/pprof/heap /metrics; do
    status=$(request GET "$p")
    [[ $status == 404 ]] && ok "OPS-1: GET $p through Envoy: 404" || miss "OPS-1: GET $p through Envoy is 404 (status $status)"
  done
  control_healthz
}

ops2() {
  local kind out want status h
  out=$(kc get httproutes.gateway.networking.k8s.io -A -o json | jq -r '.items[]
    | "\(.metadata.namespace)/\(.metadata.name) \(.spec.hostnames | join(",")) \([.spec.rules[].backendRefs[]? | "\(.namespace // "-")/\(.name)"] | unique | join(","))"' | LC_ALL=C sort)
  want="svp-data/s3 s3.svp.localhost -/minio
svp/api api.svp.localhost -/gateway,-/gateway-canary
svp/web svp.localhost -/web,-/web-canary"
  [[ $out == "$want" ]] && ok "OPS-2: HTTPRoutes are exactly svp/api (api.svp.localhost to gateway, gateway-canary), svp/web (svp.localhost to web, web-canary) and svp-data/s3 (s3.svp.localhost to minio)" ||
    miss "OPS-2: HTTPRoutes are exactly svp/api, svp/web and svp-data/s3 (got: $(tr '\n' ';' <<<"$out"))"
  for kind in grpcroutes.gateway.networking.k8s.io tlsroutes.gateway.networking.k8s.io tcproutes.gateway.networking.k8s.io \
    udproutes.gateway.networking.k8s.io ingresses.networking.k8s.io; do
    if out=$(kc get "$kind" -A -o name 2>&1); then
      [[ -z $out ]] && ok "OPS-2: no ${kind%%.*}" || miss "OPS-2: no ${kind%%.*} (got: $(tr '\n' ' ' <<<"$out"))"
    elif grep -q "doesn't have a resource type" <<<"$out"; then
      ok "OPS-2: no ${kind%%.*} (resource type not installed)"
    else
      miss "OPS-2: list ${kind%%.*} ($out)"
    fi
  done
  out=$(kc get services -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer" or .spec.type == "NodePort")
    | "\(.metadata.namespace)/\(.metadata.name) \(.spec.type) \(.metadata.labels["gateway.envoyproxy.io/owning-gateway-name"] // "-")"')
  [[ $(wc -l <<<"$out" | tr -d ' ') == 1 && $out == "envoy-gateway-system/envoy-svp-edge-svp-"*" LoadBalancer svp" ]] &&
    ok "OPS-2: the only LoadBalancer or NodePort Service is Envoy's of Gateway svp ($out)" ||
    miss "OPS-2: the only LoadBalancer or NodePort Service is Envoy's of Gateway svp (got: $(tr '\n' ';' <<<"$out"))"
  out=$(kc get pods -A -o json | jq -r '.items[] | select(.metadata.namespace != "kube-system")
    | select(.spec.hostNetwork == true or any(.spec.containers[].ports[]?; .hostPort != null)) | "\(.metadata.namespace)/\(.metadata.name)"')
  [[ -z $out ]] && ok "OPS-2: no pod outside kube-system uses the host network or a hostPort" ||
    miss "OPS-2: no pod outside kube-system uses the host network or a hostPort (got: $(tr '\n' ' ' <<<"$out"))"
  if kc get namespace argocd >/dev/null 2>&1; then
    info "OPS-2: Argo CD is installed; its Services are covered by the LoadBalancer/NodePort check above"
  else
    info "OPS-2: Argo CD is not installed on this cluster (dev path); nothing of it can be exposed"
  fi

  for h in grafana prometheus alertmanager glitchtip argocd; do
    status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "https://$h.svp.localhost:8443/" || true)
    [[ $status == 404 ]] && ok "OPS-2: https://$h.svp.localhost:8443/ at Envoy: 404 (no route)" ||
      miss "OPS-2: https://$h.svp.localhost:8443/ at Envoy is 404 (status $status)"
  done
  control_healthz

  status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$grafana_port/api/user" || true)
  [[ $status == 401 ]] && ok "OPS-2: Grafana /api/user without a login: 401" || miss "OPS-2: Grafana /api/user without a login is 401 (status $status)"
  status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$grafana_port/api/search" || true)
  [[ $status == 401 ]] && ok "OPS-2: Grafana /api/search (dashboards) without a login: 401" ||
    miss "OPS-2: Grafana /api/search without a login is 401 (status $status)"
  status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$grafana_port/api/health" || true)
  [[ $status == 200 ]] && control "Grafana /api/health: 200 (Grafana answers)" || miss "control: Grafana /api/health is 200 (status $status)"
  # The admin login goes to curl in a private config file of $work, never on a command line.
  kc -n svp-obs get secret grafana-admin -o json |
    jq -r '"user = \(((.data["admin-user"] | @base64d) + ":" + (.data["admin-password"] | @base64d)) | @json)"' >"$work/grafana.curl" ||
    fail "OPS-2: read the Grafana admin login from Secret svp-obs/grafana-admin"
  status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -K "$work/grafana.curl" "http://127.0.0.1:$grafana_port/api/user" || true)
  rm -f "$work/grafana.curl"
  [[ $status == 200 ]] && control "Grafana /api/user with the admin login: 200" || miss "control: Grafana /api/user with the admin login is 200 (status $status)"
}

# The limit of class login-ip (services/gateway/internal/ratelimit/ratelimit.go: 60 per minute, burst 30, so one
# request refilled per second) and the logins of one attempt.
rl1_burst=30
rl1_n=40
# Logins in flight at once over the one connection. With all 40 at once, each gateway pod (two at rest; CPU limit 1, and
# Go never sets GOMAXPROCS below 2 from a cgroup limit, so 2) had about 20 requests queued, and under host load some
# read their Valkey reply after the gateway's 50 ms store timeout: those were decided by the pod's in-memory fallback
# limiter, in about one run in three. 8 at a time leave a few per pod; the decisions then spread over a few hundred
# milliseconds, which the refill allowance below counts.
rl1_parallel=8
# An attempt in which a login decision fell back did not test the shared bucket alone: it is printed and does not
# count, and the drill tries again once the login-ip bucket is full, up to this many attempts in all.
rl1_attempts=3
# The interval of class login-email (10 per hour): a new login-email key holds the time of its decision plus this.
login_email_interval_ms=360000
# The fallback login decisions of the gateway pods: one set of series per process, told apart by label instance.
rl1_fallback_series='svp_ratelimit_decisions_total{job="gateway",class=~"login-ip|login-email",store="fallback"}'

# valkey_now: the seconds of Valkey's clock, which is the clock of every pod of the cluster (one Docker VM), the
# gateway's and Prometheus' included.
valkey_now() { valkey TIME | sed -n 1p; }

# rl1_send ATTEMPT: waits until no login-ip bucket is left in Valkey, sends the logins of attempt ATTEMPT, and reads
# what the checks need right after them, before the login-ip bucket refills: Valkey's time around the burst
# (rl1_t_start, rl1_t_end), the gateway's pods as it starts (rl1_pods_before, from gateway_pods), the answers
# (rl1_passed, rl1_limited, rl1_busy, rl1_other; $work/rl1.passed, $work/rl1.other), the login keys ($work/rl-keys;
# $work/ip-pttl: "KEY PTTL" per login-ip key) and the spread of the decisions in ms (rl1_spread, empty when unknown).
rl1_send() {
  local a=$1 deadline i email status code connects versions key h
  deadline=$((SECONDS + 45))
  until valkey --scan --pattern 'svp:gw:rl:login-ip:*' >"$work/ip-keys" && [[ ! -s $work/ip-keys ]]; do
    ((SECONDS < deadline)) || fail "RL-1: every login-ip bucket in Valkey db 10 expired within 45 s (still: $(tr '\n' ' ' <"$work/ip-keys"))"
    sleep 2
  done
  ok "RL-1: attempt $a: no login-ip bucket in Valkey db 10: the bucket of the address the gateway sees is full"

  : >"$work/rl1.curl"
  : >"$work/rl1.hashes"
  for ((i = 1; i <= rl1_n; i++)); do
    ((i == 1)) || echo next >>"$work/rl1.curl"
    email="drill-rl1-$run_id-$a-$i@example.test"
    DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" '{email: $e, password: env.DRILL_PASSWORD}' >"$work/rl1-$i.json"
    echo "$i $(email_hash "$email")" >>"$work/rl1.hashes"
    # Two forged hops per request, new ones each time (TEST-NET addresses, RFC 5737).
    cat >>"$work/rl1.curl" <<EOF
url = "$base/auth/login"
http2
max-time = 20
header = "Content-Type: application/json"
header = "X-Forwarded-For: 198.51.100.$i, 203.0.113.$i"
data-binary = "@$work/rl1-$i.json"
output = "$work/rl1-$i.out"
write-out = "$i %{http_code} %{num_connects} %{http_version}\n"
EOF
  done
  rl1_t_start=$(valkey_now)
  # valkey-cli through kubectl exec runs in the Valkey container, so its CPU counts against Valkey's CPU limit, which
  # one exec can use up for the current 100 ms period: Valkey then waits for the next period, longer than the
  # gateway's 50 ms. The logins start a second after the drill's last exec there.
  sleep 1
  rl1_pods_before=$(gateway_pods) || rl1_pods_before=
  curl -sS --parallel --parallel-max "$rl1_parallel" -K "$work/rl1.curl" >"$work/rl1.wo" || true
  rl1_t_end=$(valkey_now)
  [[ $rl1_t_start =~ ^[0-9]+$ && $rl1_t_end =~ ^[0-9]+$ ]] ||
    fail "RL-1: read Valkey's clock around the burst (got '$rl1_t_start', '$rl1_t_end')"
  connects=$(awk '{ n += $3 } END { print n + 0 }' "$work/rl1.wo")
  versions=$(awk '{ print $4 }' "$work/rl1.wo" | sort -u | tr '\n' ' ')
  [[ $connects == 1 && $versions == "2 " && $(wc -l <"$work/rl1.wo" | tr -d ' ') == "$rl1_n" ]] ||
    fail "RL-1: the $rl1_n logins went over one HTTP/2 connection (connections $connects, HTTP versions $versions, answers $(wc -l <"$work/rl1.wo" | tr -d ' '))"
  rl1_passed=0 rl1_limited=0 rl1_busy=0 rl1_other=0
  : >"$work/rl1.passed"
  : >"$work/rl1.other"
  while read -r i status _; do
    code=$(jq -r '.code // ""' "$work/rl1-$i.out" 2>/dev/null || true)
    case "$status $code" in
      "429 RATE_LIMITED") rl1_limited=$((rl1_limited + 1)) ;;
      "401 INVALID_CREDENTIALS") rl1_passed=$((rl1_passed + 1)) && echo "$i" >>"$work/rl1.passed" ;;
      # user-service's bound on concurrent password hashes (JWT-9): past the rate limit, refused by user-service.
      "429 SERVER_BUSY") rl1_passed=$((rl1_passed + 1)) rl1_busy=$((rl1_busy + 1)) && echo "$i" >>"$work/rl1.passed" ;;
      *) rl1_other=$((rl1_other + 1)) && echo "request $i: $status ${code:-no code}" >>"$work/rl1.other" ;;
    esac
  done <"$work/rl1.wo"

  # The PTTL of a login-ip key falls from the end of the burst on: read first.
  valkey --scan --pattern 'svp:gw:rl:login-*' >"$work/rl-keys" || fail "RL-1: scan the login keys"
  : >"$work/ip-pttl"
  while read -r key; do
    [[ $key == svp:gw:rl:login-ip:* ]] || continue
    echo "$key $(valkey PTTL "$key")" >>"$work/ip-pttl"
  done <"$work/rl-keys"
  # The bucket refills one request per second, so decisions spread over S ms let up to floor(S / 1000) more through
  # than the burst. S is measured on the login-email keys of the logins that passed: a new key holds its decision's
  # time in Valkey's clock plus the interval of login-email. Each login-email decision follows its login-ip decision
  # within one Valkey call (over 50 ms, the call falls back, which rl1_fallback catches); 100 ms covers it.
  : >"$work/rl1.email-keys"
  while read -r i; do
    h=$(awk -v i="$i" '$1 == i { print $2 }' "$work/rl1.hashes")
    grep ":$h\$" "$work/rl-keys" >>"$work/rl1.email-keys" || true
  done <"$work/rl1.passed"
  rl1_spread=
  if [[ -s $work/rl1.email-keys ]]; then
    # shellcheck disable=SC2046 # one argument per key; keys hold no space
    rl1_spread=$(valkey MGET $(cat "$work/rl1.email-keys") | awk -v iv="$login_email_interval_ms" '/^[0-9]+$/ {
      t = $1 - iv; if (n == 0 || t < min) min = t; if (n == 0 || t > max) max = t; n++ } END { if (n > 0) print max - min }') ||
      rl1_spread=
  fi
}

# gateway_pods: the gateway's server pods as one JSON line, sorted by name: name, uid, phase, whether being deleted, the
# restart count of each container. Pods that have ended (Succeeded, Failed: an evicted pod stays so) are left out, as
# no process of theirs runs. Each gateway process pushes its rate limit decisions under an instance label of its own
# (service.instance.id, random per process: internal/telemetry), which names no pod, so the processes of an attempt are
# told by their pods instead: the same line before and after the burst, every pod Running and none being deleted, means
# the same processes ran all along. A new pod, an ended, deleted or terminating one, or a restarted container changes it.
gateway_pods() {
  kc -n svp get pods -l app.kubernetes.io/name=gateway,app.kubernetes.io/component=server -o json |
    jq -c '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | {name: .metadata.name, uid: .metadata.uid, phase: .status.phase,
      deleting: (.metadata.deletionTimestamp != null), restarts: [.status.containerStatuses[]?.restartCount]}]
      | sort_by(.name)'
}

# pods_summary LINE: a line of gateway_pods for people: each pod's name, phase, restarts, and whether being deleted.
pods_summary() {
  jq -r 'map("\(.name) \(.phase) restarts \(.restarts | map(tostring) | join("/"))\(if .deleting then " being deleted" else "" end)")
    | join(", ")' <<<"${1:-[]}" 2>/dev/null || echo "not read"
}

# rl1_fallback: whether a login decision of the last burst fell back to a gateway pod's in-memory limiter. Each pod
# counts its decisions in svp_ratelimit_decisions_total by store and pushes them every 15 s, each sample stamped with
# the time it was read. The attempt is judged only when the gateway's pods (gateway_pods) were the same before the
# burst and once every one of them has pushed after it, all Running and none being deleted: then exactly as many
# instances as pods have a sample stamped after the burst (a process that is gone pushes nothing new, and one more
# instance than pods is a process the pods do not account for), and the fallback login decisions of each in its latest
# sample are compared with those in its last sample before the burst (an instant query at rl1_t_start), instance by
# instance. Sets rl1_fell to 0 when they are equal on every one (rl1_pods: how many), else to what grew or why it cannot
# be told.
rl1_fallback() {
  local pods deadline fresh n after before now i d grew=0 on=0 unknown=0
  local since=$((rl1_t_end + 1))
  if [[ -z $rl1_pods_before ]] ||
    ! jq -e 'length > 0 and all(.[]; .phase == "Running" and (.deleting | not))' <<<"$rl1_pods_before" >/dev/null; then
    rl1_fell="unknown: the gateway's pods as the burst started were not read, or not all Running and kept ($(pods_summary "$rl1_pods_before"))"
    return 0
  fi
  pods=$(jq length <<<"$rl1_pods_before")
  deadline=$((SECONDS + 90))
  while :; do
    fresh=$(promql "min by (instance) (timestamp($rl1_fallback_series))") || fresh='[]'
    n=$(jq --argjson since "$since" '[.[] | select((.value[1] | tonumber) > $since)] | length' <<<"$fresh") || n=0
    ((n >= pods)) && break
    if ((SECONDS >= deadline)); then
      rl1_fell="unknown: $n of the $pods gateway pods pushed their rate limit decisions after the burst within 90 s"
      return 0
    fi
    sleep 3
  done
  now=$(gateway_pods) || now=
  if [[ $now != "$rl1_pods_before" ]]; then
    rl1_fell="unknown: the gateway's pods changed during the attempt (before the burst: $(pods_summary "$rl1_pods_before"); after it: $(pods_summary "$now")), so their samples cannot stand for one another"
    return 0
  fi
  if ((n != pods)); then
    rl1_fell="unknown: $n instances pushed rate limit decisions after the burst, for $pods gateway pods that ran all along"
    return 0
  fi
  if ! after=$(promql "sum by (instance) ($rl1_fallback_series)") ||
    ! before=$(promql "sum by (instance) ($rl1_fallback_series)" "$rl1_t_start"); then
    rl1_fell="unknown: Prometheus did not answer the queries of the fallback decisions"
    return 0
  fi
  jq -rn --argjson f "$fresh" --argjson a "$after" --argjson b "$before" --argjson since "$since" '
    (reduce $b[] as $x ({}; .[$x.metric.instance] = ($x.value[1] | tonumber))) as $was |
    (reduce $a[] as $x ({}; .[$x.metric.instance] = ($x.value[1] | tonumber))) as $now |
    $f[] | select((.value[1] | tonumber) > $since) | .metric.instance as $i |
    "\($i) \(if $was[$i] == null or $now[$i] == null then "none" else $now[$i] - $was[$i] end)"' >"$work/rl1-fallback" ||
    {
      rl1_fell="unknown: read the fallback decisions per pod from Prometheus' answers"
      return 0
    }
  while read -r i d; do
    if [[ ! $d =~ ^[0-9]+$ ]]; then
      unknown=$((unknown + 1))
    elif ((d > 0)); then
      on=$((on + 1)) grew=$((grew + d))
    fi
  done <"$work/rl1-fallback"
  if ((unknown > 0)); then
    rl1_fell="unknown: $unknown of the $n gateway pods with a sample after the burst have no sample before it to compare with (a pod started within 15 s of it, or Prometheus missed its samples)"
  elif ((on > 0)); then
    rl1_fell="the fallback login decisions grew by $grew on $on of the $n gateway pods: Valkey answered after the gateway's 50 ms store timeout, so those logins were decided by that pod's own limiter, not the shared bucket"
  else
    rl1_fell=0 rl1_pods=$n
  fi
}

# rl1_judge: the checks of RL-1 on what rl1_send read after the burst of an attempt that counts.
rl1_judge() {
  local refill keys key ip node pttl i h present=0 absent=0 wrong=0
  if [[ -s $work/rl1.other ]]; then sed 's/^/      /' "$work/rl1.other"; fi
  refill=$(((${rl1_spread:-0} + 100) / 1000))
  ((rl1_other == 0 && rl1_limited >= 1 && rl1_passed >= rl1_burst && rl1_passed <= rl1_burst + refill)) &&
    ok "RL-1: $rl1_n logins over one HTTP/2 connection, $rl1_parallel in flight at a time, each with a new email and its own forged X-Forwarded-For: $rl1_passed passed the rate limit (401, or 429 SERVER_BUSY from user-service's hash bound: $rl1_busy), the burst of $rl1_burst plus $((rl1_passed - rl1_burst)) refilled while the decisions spread over ${rl1_spread:-unknown} ms (up to $refill allowed); $rl1_limited got 429 RATE_LIMITED" ||
    miss "RL-1: of $rl1_n logins $rl1_burst to $((rl1_burst + refill)) pass the rate limit (the burst, plus one per second of the ${rl1_spread:-unknown} ms the decisions spread over) and the rest, at least one, get 429 RATE_LIMITED (passed $rl1_passed, limited $rl1_limited, other $rl1_other)"

  keys=$(wc -l <"$work/ip-pttl" | tr -d ' ')
  ((keys >= 1 && keys <= 2)) && ok "RL-1: login-ip keys added by the burst: $keys ($(awk '{ printf "%s ", $1 }' "$work/ip-pttl"))" ||
    miss "RL-1: the burst added 1 or 2 login-ip keys (got $keys: $(awk '{ printf "%s ", $1 }' "$work/ip-pttl"))"
  kc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}' >"$work/nodes"
  while read -r key pttl; do
    ip=${key#svp:gw:rl:login-ip:}
    node=$(awk -v ip="$ip" '{ split($2, c, "."); split(ip, a, "."); if (a[1] == c[1] && a[2] == c[2] && a[3] == c[3]) print $1 " (pod range " $2 ")" }' "$work/nodes")
    [[ $ip == 10.42.* && -n $node ]] && ok "RL-1: $ip, the address the gateway counts, is on the pod network of node $node, not a forged one" ||
      miss "RL-1: the login-ip key's address $ip is on the pod network of a node"
    ((pttl >= 20000)) && ok "RL-1: its bucket is spent: right after the burst the key lived $pttl ms more (TAT ahead of now; full again after 30 s)" ||
      miss "RL-1: the bucket of $ip is spent (PTTL $pttl ms right after the burst, want >= 20000)"
  done <"$work/ip-pttl"

  grep -qE ':(198\.51\.100|203\.0\.113)\.' "$work/rl-keys" &&
    miss "RL-1: no login-ip or login-email key is for a forged address ($(grep -cE ':(198\.51\.100|203\.0\.113)\.' "$work/rl-keys") are)" ||
    ok "RL-1: no login-ip or login-email key is for a forged address (198.51.100.0/24, 203.0.113.0/24)"
  while read -r i h; do
    if grep -q ":$h\$" "$work/rl-keys"; then
      grep -qx "$i" "$work/rl1.passed" && present=$((present + 1)) || wrong=$((wrong + 1))
    else
      grep -qx "$i" "$work/rl1.passed" && wrong=$((wrong + 1)) || absent=$((absent + 1))
    fi
  done <"$work/rl1.hashes"
  ((wrong == 0 && present == rl1_passed && absent == rl1_limited)) &&
    ok "RL-1: login-email keys exist for the $present emails that passed and for none of the $absent that got 429: login-ip refused those, before login-email was asked; no login-email bucket refused anything" ||
    miss "RL-1: login-email keys exist exactly for the emails that passed (present $present, absent $absent, mismatched $wrong)"
}

rl1() {
  local a
  for ((a = 1; a <= rl1_attempts; a++)); do
    rl1_send "$a"
    rl1_fallback
    if [[ $rl1_fell == 0 ]]; then
      ok "RL-1: attempt $a of $rl1_attempts counts: no login decision fell back to a gateway pod's in-memory limiter (on each of the $rl1_pods gateway pods, the fallback decisions of login-ip and login-email in a sample after the burst equal those in its last sample before it)"
      rl1_judge
      return 0
    fi
    info "RL-1: attempt $a of $rl1_attempts does not count: $rl1_fell (it saw: passed $rl1_passed, limited $rl1_limited, other $rl1_other, decisions spread over ${rl1_spread:-unknown} ms, $(wc -l <"$work/ip-pttl" | tr -d ' ') login-ip key(s): $(awk '{ printf "%s PTTL %s ms; ", $1, $2 }' "$work/ip-pttl"))"
  done
  miss "RL-1: an attempt in which no login decision fell back to a gateway pod's in-memory limiter, within $rl1_attempts attempts (each is above): the shared login-ip bucket was not tested on its own"
}

# psa_platform: Pod Security "restricted" enforced, at the version chart svp-cluster pins, on every namespace of the
# cluster but Kubernetes' own: kube-system (k3s's control plane, and servicelb's pods, which need NET_ADMIN),
# kube-public, kube-node-lease and default, where nothing of the lab runs. That is the project's namespaces and the
# platform charts' (cert-manager, envoy-gateway-system, cnpg-system, keda, argo-rollouts, kyverno; argocd on the
# GitOps path), where whoever may create pods (a controller, taken over) could, without any Pod Security, start a
# privileged pod with a hostPath of the node and read every Secret of the cluster from it. The cluster default below
# already refuses that in a namespace without labels; the label is still required: it pins the level and version on
# the namespace itself, visible there and independent of the API server's configuration, and the default is only the
# net for a namespace whose label is missing. Every namespace counts, not a list kept here: one that a new chart
# brings without the label fails. Each namespace of deploy/argocd/apps/components.json must be among them.
# default, kube-public and kube-node-lease have no label: there the cluster default of the API server
# (deploy/k8s/pod-security-admission.yaml) holds, shown by a privileged pod it refuses at the same level and version;
# a label on one of them (privileged, say) would override the default, so they must have none.
psa_platform() {
  local version=$psa_version ns level got out n=0
  kc get namespaces -o json | jq -r '.items[] | [.metadata.name,
    (.metadata.labels["pod-security.kubernetes.io/enforce"] // "-"),
    (.metadata.labels["pod-security.kubernetes.io/enforce-version"] // "-")] | @tsv' >"$work/psa-namespaces" ||
    fail "PSA-platform: list the namespaces of the cluster"
  while IFS=$'\t' read -r ns level got; do
    case $ns in kube-system | kube-public | kube-node-lease | default) continue ;; esac
    n=$((n + 1))
    [[ $level == restricted && $got == "$version" ]] && ok "PSA-platform: namespace $ns enforces PSA restricted $version" ||
      miss "PSA-platform: namespace $ns enforces PSA restricted $version (got enforce '$level', version '$got')"
  done <"$work/psa-namespaces"
  for ns in $(jq -r '.components[].namespace' "$repo_root/deploy/argocd/apps/components.json" | sort -u); do
    awk -F '\t' -v ns="$ns" '$1 == ns { found = 1 } END { exit !found }' "$work/psa-namespaces" ||
      miss "PSA-platform: namespace $ns of deploy/argocd/apps/components.json exists"
  done
  ((n > 0)) || miss "PSA-platform: the cluster has namespaces besides kube-system, kube-public, kube-node-lease and default"
  for ns in default kube-public kube-node-lease; do
    level=$(awk -F '\t' -v ns="$ns" '$1 == ns { print $2 }' "$work/psa-namespaces")
    if [[ $level != - ]]; then
      miss "PSA-platform: namespace $ns exists without a PSA enforce label, so the cluster default applies (got '$level')"
      continue
    fi
    out=$(privileged_pod "$ns" | kc create --dry-run=server -f - 2>&1 || true)
    grep -qF "violates PodSecurity \"restricted:$version\"" <<<"$out" &&
      ok "PSA-platform: a privileged pod with the node's / as hostPath is Forbidden in $ns by the cluster default restricted $version (server-side dry run)" ||
      miss "PSA-platform: a privileged pod is Forbidden in $ns by the cluster default restricted:$version (got: $(head -n 1 <<<"$out"))"
    out=$(psa_pod 65532 "$ns" | kc create --dry-run=server -f - 2>&1 || true)
    grep -q 'created (server dry run)' <<<"$out" && control "a restricted pod is admitted in $ns (server-side dry run)" ||
      miss "control: a restricted pod is admitted in $ns (got: $(head -n 1 <<<"$out"))"
  done
  info "PSA-platform: kube-system is exempt from the cluster default (deploy/k8s/pod-security-admission.yaml): k3s's svclb-* pods need NET_ADMIN, local-path-provisioner's helper pods a hostPath of the node; whoever may create pods there (cert-manager's controller, which may in every namespace, among them) can still start a privileged pod"
}

# rand_uuid: a random id in the canonical UUID form (the BFF's id pattern).
rand_uuid() { openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})/\1-\2-\3-\4-/'; }

# web7_redirect PATH STATUS: the check of a probe with %2F that answered a redirect (STATUS) rather than 400 or 404.
# Envoy Gateway's default for a path with an escaped slash (%2F, %5C) is UnescapeAndRedirect (ClientTrafficPolicy
# path.escapedSlashesAction; the repo sets none): Envoy answers 307 to the unescaped, normalised path itself, before the
# web client sees the request. That is no way past the BFF's list as long as the Location stays on the web client's
# origin (a path, or https://svp.localhost:8443/...), holds no escaped slash, and answers 400 or 404 there in turn.
web7_redirect() {
  local p=$1 status=$2 loc follow
  loc=$(tr -d '\r' <"$work/web7-probe.headers" | awk 'tolower($1) == "location:" { v = $2 } END { print v }')
  loc=${loc#"$web_base"}
  if [[ $loc != /* || $loc == //* || $loc == *\\* ]] || grep -qiE '%2f|%5c' <<<"$loc"; then
    miss "WEB-7: GET $p redirects ($status) to a path of the web client's origin with no escaped slash left (Location '${loc}')"
    return 0
  fi
  follow=$(web_get "$loc" "$work/web7-follow" --path-as-is)
  [[ $follow == 400 || $follow == 404 ]] &&
    ok "WEB-7: GET $p through the web client with a session: $status to $loc (same origin, slash unescaped), which answers $follow" ||
    miss "WEB-7: GET $p redirects ($status) to $loc, which is 400 or 404 (status $follow)"
}

# web7: the BFF is no open proxy and no token reaches the browser (threat model WEB-7).
web7() {
  local p status code i ct handle id what f n=0
  web_user
  handle=$(jq -r .handle "$work/web.cred")
  id=$(rand_uuid)
  # Paths outside the BFF's list, with the session, so a refusal is the list and not a missing login. `..` goes as is
  # (--path-as-is); should Envoy or Next normalise it, the path left is /debug/pprof or /api/internal, neither of which
  # the app has: 404 as well. No path ends in / or holds //: Next answers those with a 308 to the normalised path. A
  # path with %2F may get Envoy's redirect instead (web7_redirect); none of them unescapes to a route on the list
  # (/api/videos/{id} is one, but of a random id: 404), so wherever the redirect leads is 400 or 404 too.
  local paths=(
    /api/internal/secrets /api/healthz /api/readyz /api/metrics /api/debug/pprof /api/auth/login
    "/api/public/videos/$id" "/api/videos/..%2Finternal" "/api/videos%2F$id" "/api/me%2F..%2F..%2Fdebug%2Fpprof"
    /api/feed/explore/../../../debug/pprof /api/feed/../internal /api/gateway.svp.svc.cluster.local:8080/healthz
    "/api/http:%2F%2Fuser-service.svp.svc.cluster.local:9101%2Freadyz" /api/@user-service.svp.svc.cluster.local:9101/readyz
    "/api/feed/explore?page_size=1&url=http://gateway.svp.svc.cluster.local:8080/healthz"
    "/api/feed/explore?page_size=1&page_size=2"
  )
  for p in "${paths[@]}"; do
    status=$(web_get "$p" "$work/web7-probe" --path-as-is)
    code=$(jq -r '.code // ""' "$work/web7-probe" 2>/dev/null || true)
    if [[ $status == 3?? && $p == *%2F* ]]; then
      web7_redirect "$p" "$status"
    elif [[ $status == 400 || $status == 404 ]]; then
      ok "WEB-7: GET $p through the web client with a session: $status${code:+ $code}"
    else
      miss "WEB-7: GET $p through the web client with a session is 400 or 404 (status $status${code:+, code $code})"
    fi
  done
  status=$(web_get "/api/feed/explore?page_size=1" "$work/web7-api-explore")
  [[ $status == 200 && $(jq -r '.items | type' "$work/web7-api-explore" 2>/dev/null) == array ]] &&
    control "GET /api/feed/explore?page_size=1 through the web client with the session: 200 with items (the BFF passes a listed route)" ||
    miss "control: GET /api/feed/explore?page_size=1 through the web client is 200 with items (status $status)"
  status=$(web_get /api/me "$work/web7-api-me")
  [[ $status == 200 && $(jq -r '.handle // ""' "$work/web7-api-me" 2>/dev/null) == "$handle" ]] &&
    control "GET /api/me through the web client: 200, handle @$handle (the session reaches the gateway)" ||
    miss "control: GET /api/me through the web client is 200 with handle @$handle (status $status)"

  # What the browser gets: the HTML of the pages, the RSC payloads of client navigation, the JSON of /api.
  : >"$work/web7-files"
  for p in / /me /upload "/u/$handle"; do
    i=$((i + 1))
    status=$(web_get "$p" "$work/web7-page-$i")
    [[ $status == 200 ]] && echo "$work/web7-page-$i HTML of $p" >>"$work/web7-files" ||
      miss "WEB-7: GET $p through the web client with the session is 200 (status $status)"
  done
  grep -qF "$handle" "$work/web7-page-2" &&
    control "the HTML of /me shows @$handle: the pages were rendered with the session" ||
    miss "control: the HTML of /me shows the drill user's handle (rendered with the session)"
  for p in / /me; do
    i=$((i + 1))
    # Next may answer an RSC request without its cache-busting parameter with a redirect to the URL that has it.
    status=$(web_get "$p" "$work/web7-page-$i" -H 'RSC: 1' -L --max-redirs 2)
    ct=$(tr -d '\r' <"$work/web7-page-$i.headers" | awk 'tolower($1) == "content-type:" { v = $2 } END { print v }')
    if [[ $status == 200 && $ct == text/x-component* ]]; then
      control "GET $p with RSC: 1: 200 text/x-component (the RSC payload of client navigation)"
      echo "$work/web7-page-$i RSC payload of $p" >>"$work/web7-files"
    else
      miss "control: GET $p with RSC: 1 is 200 text/x-component (status $status, content type '${ct}')"
    fi
  done
  echo "$work/web7-api-explore JSON of /api/feed/explore" >>"$work/web7-files"
  echo "$work/web7-api-me JSON of /api/me" >>"$work/web7-files"

  web_tokens
  while read -r f what; do
    n=$((n + 1))
    jwt_shaped "$f" && miss "WEB-7: the $what holds no string shaped like a JWT (it does)" ||
      ok "WEB-7: the $what holds no string shaped like a JWT"
    p=$(holds "$work/web.tokens" "$f")
    [[ -z $p ]] && ok "WEB-7: the $what holds none of the session's access token, refresh token and sid" ||
      miss "WEB-7: the $what holds none of the session's tokens (found: $p)"
  done <"$work/web7-files"
  ((n >= 8)) || miss "WEB-7: 8 answers searched (4 pages, 2 RSC payloads, 2 /api JSON; got $n)"
  # Controls of the search: it finds the token of a login answered by the gateway itself, and the session's access
  # token. The gateway's answer is dropped at once.
  jq '{email, password}' "$work/web.cred" >"$work/web7-login.json"
  status=$(request POST /auth/login "" "$work/web7-login.json")
  if [[ $status == 200 ]] && jwt_shaped "$work/body"; then
    control "the same search finds a JWT in the gateway's own login answer ($base/auth/login, 200)"
  else
    miss "control: the same search finds a JWT in the gateway's own login answer (status $status)"
  fi
  : >"$work/body"
  awk -F '\t' '$1 == "access-token" { print $2 }' "$work/web.tokens" >"$work/web7-access"
  jwt_shaped "$work/web7-access" && control "the same search finds the session's access token (shaped like a JWT)" ||
    miss "control: the session's access token is shaped like a JWT, as the search expects"
  rm -f "$work/web7-access" "$work/web7-login.json"
}

# The ways WEB-2 sends a POST from outside the app, as "HEADER|HEADER" (none: neither Sec-Fetch-Site nor Origin).
web2_variants=(
  "Sec-Fetch-Site: cross-site|Origin: https://evil.example"
  "Sec-Fetch-Site: same-site|Origin: $s3_origin"
  "Origin: https://evil.example"
  "Origin: $s3_origin"
  "Origin: null"
  ""
)

# web2_send TARGET VARIANT OUT: POSTs to TARGET (action, api, logout, rum, monitoring) with the session cookie and the
# headers of VARIANT ("HEADER|HEADER"); the body to OUT, prints the HTTP status. action is the /login form's Server
# Action, posted with the config of $work/web2-login.curl (web_form_config). args stays empty for the variant with
# neither header: ${args[@]+...} expands it to nothing, where a plain "${args[@]}" of an empty array stops bash 3.2
# (macOS /bin/bash) under set -u with "unbound variable".
web2_send() {
  local h hs args=()
  if [[ -n $2 ]]; then
    IFS='|' read -r -a hs <<<"$2"
    for h in "${hs[@]}"; do args+=(-H "$h"); done
  fi
  case $1 in
    action)
      : >"$3"
      curl -sS --max-time 15 -o "$3" -w '%{http_code}' -b "$work/web.jar" -K "$work/web2-login.curl" \
        ${args[@]+"${args[@]}"} || true
      ;;
    api) web_post /api/videos "$3" -H 'Content-Type: application/json' --data-binary '{}' ${args[@]+"${args[@]}"} ;;
    logout) web_post /logout "$3" ${args[@]+"${args[@]}"} ;;
    rum)
      web_post /rum "$3" -H 'Content-Type: text/plain;charset=UTF-8' \
        --data-binary '{"path":"/","metrics":[{"name":"LCP","value":1200}]}' ${args[@]+"${args[@]}"}
      ;;
    monitoring)
      web_post /monitoring "$3" -H 'Content-Type: text/plain;charset=UTF-8' --data-binary '{}' ${args[@]+"${args[@]}"}
      ;;
  esac
}

# web2: no request from another site, or from s3.svp.localhost, changes state with the session (threat model WEB-2).
web2() {
  local t v what status code same="Sec-Fetch-Site: same-origin|Origin: $web_base"
  web_user
  # The login form's Server Action, logged out: AuthPage sends a logged-in visitor of /login to the home page.
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "drill-web2-$run_id-$(openssl rand -hex 4)@example.test" \
    '{email: $e, password: env.DRILL_PASSWORD}' >"$work/web2-wrong.cred"
  web_jar=$work/anon.jar web_form_config /login "$work/web2-wrong.cred" "$work/web2-login.curl"
  for t in action api logout rum monitoring; do
    for v in "${web2_variants[@]}"; do
      what=${v:-neither Sec-Fetch-Site nor Origin}
      status=$(web2_send "$t" "$v" "$work/web2.out")
      code=$(jq -r '.code // ""' "$work/web2.out" 2>/dev/null || true)
      [[ $status == 403 && $code == CSRF_REJECTED ]] &&
        ok "WEB-2: POST $t with the session cookie and ${what//|/, }: 403 CSRF_REJECTED" ||
        miss "WEB-2: POST $t with the session cookie and ${what//|/, } is 403 CSRF_REJECTED (status $status, code '${code}')"
    done
    if [[ $t == logout ]]; then
      status=$(web_get /api/me "$work/web2.out")
      [[ $status == 200 ]] && ok "WEB-2: after the refused logouts the session still works (GET /api/me 200)" ||
        miss "WEB-2: after the refused logouts the session still works (GET /api/me: status $status)"
    fi
  done

  # Controls: the same POSTs from the app's own pages pass the check.
  : >"$work/web2.out"
  status=$(curl -sS --max-time 15 -o "$work/web2.out" -w '%{http_code}' -K "$work/web2-login.curl" \
    -H 'Sec-Fetch-Site: same-origin' -H "Origin: $web_base" || true)
  [[ $status == 200 && $(form_error "$work/web2.out") == wrong-credentials ]] &&
    control "POST of the /login form's Server Action from the app's origin (logged out, wrong password): 200, the form shows \"Wrong email or password\" (the action ran and asked the gateway)" ||
    miss "control: the /login form's Server Action from the app's origin answers 200 with \"Wrong email or password\" (status $status, form error $(form_error "$work/web2.out"))"
  status=$(web2_send api "$same" "$work/web2.out")
  code=$(jq -r '.code // ""' "$work/web2.out" 2>/dev/null || true)
  [[ $status == 400 && $code != CSRF_REJECTED ]] &&
    control "POST /api/videos with an empty object from the app's origin: 400 ${code} from the gateway, past the check" ||
    miss "control: POST /api/videos with an empty object from the app's origin reaches the gateway, 400 (status $status, code '${code}')"
  status=$(web2_send rum "$same" "$work/web2.out")
  [[ $status == 204 ]] && control "POST /rum with a beacon from the app's origin: 204" ||
    miss "control: POST /rum with a beacon from the app's origin is 204 (status $status)"
  status=$(web2_send monitoring "$same" "$work/web2.out")
  code=$(jq -r '.code // ""' "$work/web2.out" 2>/dev/null || true)
  [[ $status == 400 && $code == INVALID_REPORT ]] &&
    control "POST /monitoring with an empty object from the app's origin: 400 INVALID_REPORT (checked, nothing sent)" ||
    miss "control: POST /monitoring with an empty object from the app's origin is 400 INVALID_REPORT (status $status, code '${code}'; 404 means SENTRY_DSN is empty in Secret svp/sentry)"
  # The logout clears the cookie (Max-Age=0), so curl drops it from the jar; a copy of the jar from before sends the old
  # sid again, which shows the server deleted the session, not only the cookie.
  cp "$work/web.jar" "$work/web2-old.jar"
  status=$(web2_send logout "$same" "$work/web2.out")
  [[ $status == 303 ]] && control "POST /logout from the app's origin: 303" ||
    miss "control: POST /logout from the app's origin is 303 (status $status)"
  [[ -z $(web_sid) ]] && control "the logout cleared the session cookie (no $web_cookie left in the cookie jar)" ||
    miss "control: the logout clears the session cookie (it is still in the cookie jar)"
  status=$(web_jar=$work/web2-old.jar web_get /api/me "$work/web2.out")
  rm -f "$work/web2-old.jar"
  [[ $status == 401 ]] && control "after it the old session id sent again is refused: GET /api/me 401 (the session was deleted on the server)" ||
    miss "control: after the logout GET /api/me with the old session id is 401 (status $status)"
}

# web10: MinIO's CORS answers the web client's origin only (threat model WEB-10).
web10() {
  local t path method origin status acao
  for t in "/media/media/drill-threats-$run_id/master.m3u8 GET" "/uploads POST"; do
    read -r path method <<<"$t"
    for origin in https://evil.example http://localhost:3001 http://localhost:3002 "$web_base"; do
      : >"$work/cors.headers"
      status=$(curl -s --max-time 5 -o /dev/null -D "$work/cors.headers" -w '%{http_code}' -X OPTIONS \
        -H "Origin: $origin" -H "Access-Control-Request-Method: $method" "$s3_origin$path" || true)
      acao=$(tr -d '\r' <"$work/cors.headers" | awk 'tolower($1) == "access-control-allow-origin:" { print $2 }')
      if [[ $origin == "$web_base" ]]; then
        [[ $status == 2?? && $acao == "$origin" ]] &&
          control "OPTIONS $s3_origin$path ($method) from $origin: $status, Access-Control-Allow-Origin $acao" ||
          miss "control: OPTIONS $s3_origin$path ($method) from $origin is 2xx with Access-Control-Allow-Origin $origin (status $status, got '${acao}')"
      else
        [[ $status != 000 && -z $acao ]] &&
          ok "WEB-10: OPTIONS $s3_origin$path ($method) from $origin: $status without Access-Control-Allow-Origin" ||
          miss "WEB-10: OPTIONS $s3_origin$path ($method) from $origin answers without Access-Control-Allow-Origin (status $status, got '${acao}')"
      fi
    done
  done
}

# The probes of WEB-13, run by the web image's node (distroless: no shell, no nc): for each HOST:PORT argument one line
# "HOST PORT DNS STATE" as reach() writes them: DNS dns when the name resolves, nodns when not, ip for an address; STATE
# open when a TCP connection opens within 3 s, closed otherwise.
# shellcheck disable=SC2016 # JavaScript
web13_js='
const net = require("node:net");
const dns = require("node:dns");
const probe = (target) => new Promise((done) => {
  const i = target.lastIndexOf(":");
  const host = target.slice(0, i);
  const port = Number(target.slice(i + 1));
  const connect = (resolved) => {
    const socket = net.connect({ host, port, timeout: 3000 });
    const end = (state) => { socket.destroy(); done(`${host} ${port} ${resolved} ${state}`); };
    socket.once("connect", () => end("open"));
    socket.once("timeout", () => end("closed"));
    socket.once("error", () => end("closed"));
  };
  if (net.isIP(host) !== 0) connect("ip");
  else dns.lookup(host, (error) => connect(error ? "nodns" : "dns"));
});
Promise.all(process.argv.slice(1).map(probe)).then((lines) => console.log(lines.join("\n")));
'

# web13: the web pods reach only the gateway, Valkey, the Collector and GlitchTip; only Envoy reaches them (threat model
# WEB-13).
web13() {
  local pod t
  local closed=(
    1.1.1.1:443 example.com:443 svp-pg-rw.svp-data.svc.cluster.local:5432 redpanda.svp-data.svc.cluster.local:9092
    redpanda-0.redpanda.svp-data.svc.cluster.local:9644 minio.svp-data.svc.cluster.local:9000
    user-service.svp.svc.cluster.local:9101 video-service.svp.svc.cluster.local:9102
    engagement-service.svp.svc.cluster.local:9103 feed-service.svp.svc.cluster.local:9104
    pyroscope.svp-obs.svc.cluster.local:4040 kubernetes.default.svc.cluster.local:443
  )
  local open=(
    gateway.svp.svc.cluster.local:8080 valkey.svp-data.svc.cluster.local:6379
    otel-collector.svp-obs.svc.cluster.local:4317 glitchtip.svp-obs.svc.cluster.local:8000
  )
  web_pods >"$work/web-pods" || fail "WEB-13: list the web pods ($web_selector)"
  [[ -s $work/web-pods ]] || fail "WEB-13: namespace svp has running web pods ($web_selector)"
  while read -r pod _; do
    if ! kc -n svp exec "$pod" -c web -- /nodejs/bin/node -e "$web13_js" "${closed[@]}" "${open[@]}" \
      </dev/null >"$work/reach"; then
      miss "WEB-13: run the connection probes with node in web pod $pod"
      continue
    fi
    for t in "${closed[@]}"; do expect_reach "$t" closed "WEB-13: from web pod $pod"; done
    for t in "${open[@]}"; do expect_reach "$t" open "WEB-13: from web pod $pod (control of the closed ones)"; done
  done <"$work/web-pods"
  info "WEB-13: the internet has no control case from the web pods: example.com resolved there, so its failure is the connection"
  reach "$probe_ns" pod/probe web.svp.svc.cluster.local:3001
  expect_reach web.svp.svc.cluster.local:3001 closed "WEB-13: from $probe_ns, the web client"
  control_web_edge
}

# The logins of one WEB-8 attempt and how many are in flight at once over the one connection (as RL-1).
web8_n=40
web8_parallel=8

# web8_send ATTEMPT: waits until no login-ip bucket is left in Valkey, sends the logins of attempt ATTEMPT through the
# web client's /login form and reads, right after them, what the checks need: Valkey's time around the burst and the
# gateway's pods as it starts (rl1_t_start, rl1_t_end, rl1_pods_before, for rl1_fallback), the login keys
# ($work/rl-keys) and each answer's form error ($work/web8.answers: "I STATUS ERROR").
web8_send() {
  local a=$1 deadline i email connects versions status
  deadline=$((SECONDS + 45))
  until valkey --scan --pattern 'svp:gw:rl:login-ip:*' >"$work/ip-keys" && [[ ! -s $work/ip-keys ]]; do
    ((SECONDS < deadline)) || fail "WEB-8: every login-ip bucket in Valkey db 10 expired within 45 s (still: $(tr '\n' ' ' <"$work/ip-keys"))"
    sleep 2
  done
  ok "WEB-8: attempt $a: no login-ip bucket in Valkey db 10"

  # The form's hidden Server Action fields, read once and logged out (they are the same for every post of a build).
  status=$(web_jar=$work/anon.jar web_get /login "$work/web8-login.html")
  [[ $status == 200 ]] || fail "WEB-8: GET /login of the web client is 200 (status $status)"
  form_fields "$work/web8-login.html" >"$work/web8-hidden" || fail "WEB-8: the /login form has hidden Server Action fields"
  : >"$work/web8.curl"
  : >"$work/web8.hashes"
  for ((i = 1; i <= web8_n; i++)); do
    ((i == 1)) || echo next >>"$work/web8.curl"
    email="drill-web8-$run_id-$a-$i@example.test"
    DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" '{email: $e, password: env.DRILL_PASSWORD}' >"$work/web8-$i.json"
    echo "$i $(email_hash "$email")" >>"$work/web8.hashes"
    {
      echo "url = \"$web_base/login\""
      echo http2
      echo "max-time = 30"
      echo "header = \"Origin: $web_base\""
      echo 'header = "Accept-Language: en"'
      # Two forged hops per request, new ones each time (TEST-NET addresses, RFC 5737), as RL-1.
      echo "header = \"X-Forwarded-For: 198.51.100.$i, 203.0.113.$i\""
      cat "$work/web8-hidden"
      jq -r 'to_entries[] | "form-string = \("\(.key)=\(.value)" | @json)"' "$work/web8-$i.json"
      echo "output = \"$work/web8-$i.out\""
      echo "write-out = \"$i %{http_code} %{num_connects} %{http_version}\\n\""
    } >>"$work/web8.curl"
  done
  rl1_t_start=$(valkey_now)
  # As RL-1: the logins start a second after the drill's last exec in the Valkey container.
  sleep 1
  rl1_pods_before=$(gateway_pods) || rl1_pods_before=
  curl -sS --parallel --parallel-max "$web8_parallel" -K "$work/web8.curl" >"$work/web8.wo" || true
  rl1_t_end=$(valkey_now)
  [[ $rl1_t_start =~ ^[0-9]+$ && $rl1_t_end =~ ^[0-9]+$ ]] ||
    fail "WEB-8: read Valkey's clock around the burst (got '$rl1_t_start', '$rl1_t_end')"
  connects=$(awk '{ n += $3 } END { print n + 0 }' "$work/web8.wo")
  versions=$(awk '{ print $4 }' "$work/web8.wo" | sort -u | tr '\n' ' ')
  [[ $connects == 1 && $versions == "2 " && $(wc -l <"$work/web8.wo" | tr -d ' ') == "$web8_n" ]] ||
    fail "WEB-8: the $web8_n logins went over one HTTP/2 connection to Envoy (connections $connects, HTTP versions $versions, answers $(wc -l <"$work/web8.wo" | tr -d ' '))"
  valkey --scan --pattern 'svp:gw:rl:login-*' >"$work/rl-keys" || fail "WEB-8: scan the login keys"
  : >"$work/web8.answers"
  while read -r i status _; do
    echo "$i $status $(form_error "$work/web8-$i.out")" >>"$work/web8.answers"
  done <"$work/web8.wo"
}

# web8_judge: the checks of WEB-8 on what web8_send read, for an attempt that counts.
web8_judge() {
  local i status error h key ip node passed=0 busy=0 limited=0 wrong=0 other=0 keys
  : >"$work/web8.email-ips"
  while read -r i status error; do
    h=$(awk -v i="$i" '$1 == i { print $2 }' "$work/web8.hashes")
    key=$(grep ":$h\$" "$work/rl-keys" | head -n 1 || true)
    case "$status $error" in
      "200 wrong-credentials") if [[ -n $key ]]; then passed=$((passed + 1)); else wrong=$((wrong + 1)); fi ;;
      # Any 429 of the gateway reads "Too many tries": with a login-email key it passed the rate limit (user-service's
      # bound on concurrent password hashes), without one login-ip refused it.
      "200 rate-limited") if [[ -n $key ]]; then busy=$((busy + 1)); else limited=$((limited + 1)); fi ;;
      *) other=$((other + 1)) && echo "      request $i: status $status, form error $error" ;;
    esac
    [[ -z $key ]] || echo "${key#svp:gw:rl:login-email:}" | sed 's/:[0-9a-f]*$//' >>"$work/web8.email-ips"
  done <"$work/web8.answers"
  ((other == 0 && wrong == 0)) &&
    ok "WEB-8: every answer is the /login form with \"Wrong email or password\" ($passed, each left its login-email key) or \"Too many tries\" ($((busy + limited)))" ||
    miss "WEB-8: every answer is the form with \"Wrong email or password\" and a login-email key, or \"Too many tries\" (other $other, wrong password without a key $wrong)"
  ((limited >= 1)) &&
    ok "WEB-8: $limited of the $web8_n logins through the web client got 429 from login-ip (no login-email key), $passed passed (burst of login-ip $rl1_burst), $busy were refused by user-service's hash bound past the limit: the forged X-Forwarded-For of each did not give it a bucket of its own" ||
    miss "WEB-8: at least one login through the web client got 429 from login-ip (limited $limited, passed $passed, busy $busy)"
  ((passed + busy >= 1)) && control "$((passed + busy)) logins through the web client passed the rate limit and reached the gateway's limiter and user-service" ||
    miss "control: logins through the web client pass the rate limit (none did)"

  grep '^svp:gw:rl:login-ip:' "$work/rl-keys" | sed 's/^svp:gw:rl:login-ip://' >"$work/web8.ips" || true
  keys=$(wc -l <"$work/web8.ips" | tr -d ' ')
  ((keys >= 1 && keys <= 2)) && ok "WEB-8: login-ip keys added by the burst: $keys ($(tr '\n' ' ' <"$work/web8.ips"))" ||
    miss "WEB-8: the burst added 1 or 2 login-ip keys (got $keys: $(tr '\n' ' ' <"$work/web8.ips"))"
  kc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}' >"$work/nodes"
  web_pods >"$work/web-pods" || true
  while read -r ip; do
    node=$(awk -v ip="$ip" '{ split($2, c, "."); split(ip, a, "."); if (a[1] == c[1] && a[2] == c[2] && a[3] == c[3]) print $1 " (pod range " $2 ")" }' "$work/nodes")
    [[ $ip == 10.42.* && -n $node ]] && ok "WEB-8: $ip, the address the gateway counts, is on the pod network of node $node" ||
      miss "WEB-8: the login-ip key's address $ip is on the pod network of a node"
    awk -v ip="$ip" '$2 == ip { found = 1 } END { exit !found }' "$work/web-pods" &&
      miss "WEB-8: $ip is not a web pod's address (it is: every web user would share its bucket)" ||
      ok "WEB-8: $ip is none of the web pods' addresses ($(awk '{ printf "%s ", $2 }' "$work/web-pods")): the gateway counts the hop Envoy wrote, not the web pod"
  done <"$work/web8.ips"
  grep -qE ':(198\.51\.100|203\.0\.113)\.' "$work/rl-keys" &&
    miss "WEB-8: no login-ip or login-email key is for a forged address ($(grep -cE ':(198\.51\.100|203\.0\.113)\.' "$work/rl-keys") are)" ||
    ok "WEB-8: no login-ip or login-email key is for a forged address (198.51.100.0/24, 203.0.113.0/24)"
  if [[ -s $work/web8.email-ips ]]; then
    sort -u "$work/web8.email-ips" | while read -r ip; do grep -qxF "$ip" "$work/web8.ips" || echo "$ip"; done >"$work/web8.stray"
    [[ ! -s $work/web8.stray ]] &&
      ok "WEB-8: the login-email keys of the logins that passed name the login-ip address(es) only ($(sort -u "$work/web8.email-ips" | tr '\n' ' '))" ||
      miss "WEB-8: the login-email keys of the logins that passed name a login-ip address (others: $(tr '\n' ' ' <"$work/web8.stray"))"
  fi
}

web8() {
  local a
  for ((a = 1; a <= rl1_attempts; a++)); do
    web8_send "$a"
    rl1_fallback
    if [[ $rl1_fell == 0 ]]; then
      ok "WEB-8: attempt $a of $rl1_attempts counts: no login decision fell back to a gateway pod's in-memory limiter (as RL-1, on each of the $rl1_pods gateway pods)"
      web8_judge
      return 0
    fi
    info "WEB-8: attempt $a of $rl1_attempts does not count: $rl1_fell"
  done
  miss "WEB-8: an attempt in which no login decision fell back to a gateway pod's in-memory limiter, within $rl1_attempts attempts (each is above)"
}

: >"$work/results"
failed=
# run_item NAME FUNCTION: runs FUNCTION in a subshell, where fail ends the item only and miss marks it failed.
run_item() {
  local rc
  echo "== $1"
  set +e
  (
    set -e
    item_failed=
    "$2"
    [[ -z $item_failed ]]
  )
  rc=$?
  set -e
  if ((rc == 0)); then
    echo "$1 PASS" >>"$work/results"
  else
    echo "$1 FAIL" >>"$work/results"
    failed+=" $1"
  fi
}

wait_gateway_ready 60
probe_up
prometheus_forward
port_free "$grafana_port" || fail "127.0.0.1:$grafana_port is in use (another port-forward?); free it and run again"
kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/kps-grafana "$grafana_port:80" \
  >"$work/grafana-forward.log" 2>&1 &
grafana_pid=$!
wait_until 20 "port-forward to Grafana on 127.0.0.1:$grafana_port" curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$grafana_port/api/health"

run_item IN-2/IN-4 in2
run_item IN-4/FF-6 in4_acl
run_item FF-5 ff5
run_item FF-3/FF-4 ff3
run_item IN-9 in9
run_item RBAC rbac
run_item OPS-1 ops1
run_item OPS-2 ops2
# WEB-7 before WEB-2: WEB-2 ends with the logout of the web session WEB-7 reads. WEB-8 after RL-1: both spend the
# login-ip bucket and wait for it to be full again.
run_item WEB-7 web7
run_item WEB-2 web2
run_item WEB-10 web10
run_item WEB-13 web13
run_item RL-1 rl1
run_item WEB-8 web8
run_item PSA-platform psa_platform
run_item BAK-1 bak1

echo
echo "drill-k8s-threats ($run_id)"
printf '  %-14s %s\n' ITEM RESULT
while read -r item result; do printf '  %-14s %s\n' "$item" "$result"; done <"$work/results"
if [[ -n $failed ]]; then
  echo "FAIL  drill-k8s-threats:$failed" >&2
  exit 1
fi
echo "drill-k8s-threats: all checks passed"
