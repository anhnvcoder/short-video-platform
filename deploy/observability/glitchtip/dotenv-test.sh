#!/usr/bin/env bash
# Tests for the strict env file rule of dotenv.sh: the rule itself, then its users, init.sh (with a
# fake COMPOSE that writes a test DSN and token where the job would), and `make env`,
# `make db-bootstrap` (deploy/postgres/bootstrap.sh), `make test-stack` and the profile check of
# `make up` (the root Makefile run in a temporary directory that links to the repository, with fake
# psql, go and docker commands that log hashes, never values). Every env file is a fixture in a
# temporary directory; the repository's .env is never read. Nothing reaches Postgres or the Docker
# daemon; when the docker CLI is installed, `make compose-hash` (compose parses the file, prints a
# hash per service) checks compose reads the quoted fixture as the plain one. Written for bash 3.2
# (the macOS /bin/bash).
#
# Usage, from anywhere: deploy/observability/glitchtip/dotenv-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
. "$here/dotenv.sh"
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# mode prints a file's permission bits (BSD stat first, GNU stat second).
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
# leftovers lists the temporary files init.sh and make env left in a directory (*.tmp.*, *.new.*).
leftovers() { ls -A "$1" | grep -E '\.(tmp|new)\.' || true; }
# lines writes its arguments one per line into a file; none makes an empty file.
lines() {
  local file=$1
  shift
  if (($#)); then printf '%s\n' "$@" > "$file"; else : > "$file"; fi
}

# --- The rule: what dotenv_value reads from each form, or that it refuses it. ---
# The value s3cr3t marks what must never reach an error message.
value_case() { # <expected value or REFUSED> <description> <env file lines...>
  local want=$1 what=$2 got err status=0
  shift 2
  lines "$work/rule.env" "$@"
  got=$(dotenv_value "$work/rule.env" SVP_T 2> "$work/rule.err") || status=$?
  err=$(cat "$work/rule.err")
  if [[ $want == REFUSED ]]; then
    if [[ $status -ne 0 && $err == *SVP_T* && $err != *s3cr3t* && -z $got ]]; then
      ok "rule: $what is refused by name"
    else
      fail "rule: $what: want refused, got status $status"
    fi
  elif [[ $status -eq 0 && $got == "$want" && -z $err ]]; then
    ok "rule: $what reads as [$want]"
  else
    fail "rule: $what: want [$want], got status $status"
  fi
}
value_case "" "a missing variable" "OTHER=1"
value_case "" "an empty file"
value_case "" "NAME=" "SVP_T="
value_case "" 'NAME=""' 'SVP_T=""'
value_case "" "NAME=''" "SVP_T=''"
value_case "v1" "a plain value" "SVP_T=v1"
value_case "v1" "a double-quoted value" 'SVP_T="v1"'
value_case "v1" "a single-quoted value" "SVP_T='v1'"
value_case "v#1" "a value with # and no blank before it" "SVP_T=v#1"
value_case "a=b" "a value with =" "SVP_T=a=b"
value_case "" "other names and comments" "SVP_TX=s3cr3t" "XSVP_T=s3cr3t" "# SVP_T=s3cr3t"
value_case "v1" "blank lines, blanks only and a # line" "" "   " "	" "#" "SVP_T=v1"
value_case "a b#c" "blanks and # in double quotes" 'SVP_T="a b#c"'
value_case "a b#c" "blanks and # in single quotes" "SVP_T='a b#c'"
value_case $'\xc3\xbc' "a non-ASCII character in quotes" $'SVP_T="\xc3\xbc"'
value_case "http://k@h:1/2?a=b&c=+/" "a URL with punctuation" "SVP_T=http://k@h:1/2?a=b&c=+/"
value_case REFUSED '${...} interpolation' 'SVP_T=${REVIEW_UNSET_VARIABLE:-}'
value_case REFUSED '$NAME interpolation' 'SVP_T=s3cr3t$HOME'
value_case REFUSED 'a $ in single quotes' "SVP_T='s3cr3t\$1'"
value_case REFUSED "an inline comment" "SVP_T=s3cr3t # comment"
value_case REFUSED "blanks then a comment" "SVP_T=   # s3cr3t"
value_case REFUSED "a quoted value then a comment" 'SVP_T="s3cr3t" # comment'
value_case REFUSED "text after the closing quote" 'SVP_T="s3cr3t"x'
value_case REFUSED "an escaped quote" 'SVP_T="s3cr3t\"x"'
value_case REFUSED "an unclosed quote" 'SVP_T="s3cr3t'
value_case REFUSED "a set line then an empty one" "SVP_T=s3cr3t" "SVP_T="
value_case REFUSED "two empty lines" "SVP_T=" "SVP_T="
value_case REFUSED "NAME= followed by blanks" "SVP_T=   "
value_case REFUSED "a value with blanks around it" "SVP_T=  s3cr3t  "
value_case REFUSED "a blank inside a plain value" "SVP_T=s3 cr3t"
value_case REFUSED "a quoted value with blanks around it" 'SVP_T= "s3cr3t" '
value_case REFUSED "a quote inside a plain value" "SVP_T=it's" "OTHER=1"
value_case REFUSED "a single quote in double quotes" 'SVP_T="it'"'"'s3cr3t"'
value_case REFUSED "a double quote in single quotes" "SVP_T='s3cr3t\"x'"
value_case REFUSED "a \\ in a plain value" 'SVP_T=s3cr3t\n'
value_case REFUSED "a \\ in single quotes" "SVP_T='s3cr3t\\'"
value_case REFUSED "a non-ASCII character in a plain value" $'SVP_T=s3cr3t\xc3\xbc'
value_case REFUSED "a trailing no-break space" $'SVP_T=s3cr3t\xc2\xa0'
value_case REFUSED "a tab in a plain value" $'SVP_T=s3cr3t\t'
value_case REFUSED "a CRLF line" $'SVP_T=s3cr3t\r'
value_case REFUSED "an empty CRLF line" $'SVP_T=\r'
value_case REFUSED "a double-quoted value over two lines" 'SVP_T="s3cr3t' 'more"'
value_case REFUSED "a single-quoted value over two lines" "SVP_T='s3cr3t" "more'"
value_case REFUSED "an escaped quote that leaves the value open" 'SVP_T="s3cr3t\"' 'more"'
value_case "v1" "an open quote in a comment" "# OTHER='s3cr3t" "SVP_T=v1"

# refused_by <variable> <description> <env file lines...>: reading SVP_T fails, naming <variable>
# (another line's variable, or the line number), never a value.
refused_by() {
  local who=$1 what=$2 got err status=0
  shift 2
  lines "$work/rule.env" "$@"
  got=$(dotenv_value "$work/rule.env" SVP_T 2> "$work/rule.err") || status=$?
  err=$(cat "$work/rule.err")
  if [[ $status -ne 0 && $err == *"$who"* && $err != *s3cr3t* && -z $got ]]; then
    ok "rule: $what is refused, naming $who"
  else
    fail "rule: $what: want refused naming $who, got status $status"
  fi
}
refused_by OTHER "SVP_T= inside another variable's quoted value" "OTHER='s3cr3t" "SVP_T=" "suffix'"
refused_by OTHER "SVP_T= inside a double-quoted one" 'OTHER="s3cr3t' "SVP_T=v1" 'suffix"'
refused_by OTHER "SVP_T= inside a single-quoted value ending in \\'" "OTHER='s3cr3t\\'" "SVP_T=" "suffix'"
refused_by OTHER "SVP_T= inside a value opened by a second NAME= on a closed line" \
  "OTHER='a' NOTE='s3cr3t" "SVP_T=" "suffix'"
refused_by OTHER "a closed value with an escaped quote on another line" 'OTHER="s3cr3t\"x"' "SVP_T=v1"
refused_by OTHER "a CRLF line of another variable" $'OTHER=s3cr3t\r' "SVP_T=v1"
refused_by OTHER "another name set twice" "OTHER=1" "OTHER=2" "SVP_T=v1"
refused_by OTHER "a line after SVP_T that breaks the rule" "SVP_T=v1" "OTHER=s3 cr3t"
refused_by "rule.env:2:" "a blank CRLF line" "SVP_T=v1" $'\r'
refused_by "rule.env:2:" "a set line then an indented empty one" "SVP_T=s3cr3t" " SVP_T="
refused_by "rule.env:1:" "a tab-indented line" "	SVP_T=s3cr3t"
refused_by "rule.env:1:" "an export line" "export SVP_T=s3cr3t"
refused_by "rule.env:1:" "a blank before =" "SVP_T =s3cr3t"
refused_by "rule.env:1:" "NAME: value" "SVP_T: s3cr3t"
refused_by "rule.env:1:" "an indented comment" "  # s3cr3t" "SVP_T=v1"
refused_by "rule.env:1:" "a name with -" "MY-NOTE='s3cr3t" "SVP_T=" "suffix'"
refused_by "rule.env:1:" "a name starting with a digit" "1OTHER='s3cr3t" "SVP_T=" "suffix'"
refused_by "rule.env:1:" "a name with [ ]" "OTHER[1]='s3cr3t" "SVP_T=" "suffix'"
refused_by "rule.env:1:" "a name with ." "OTHER.X=s3cr3t" "SVP_T=v1"
refused_by "rule.env:2:" "a line with no =" "SVP_T=v1" "s3cr3t"

# nul_case <expected FILE:LINE: and variable> <description> <printf format>: a file with a NUL byte
# (awk stops reading a line there, compose does not) is refused by dotenv_value and by dotenv_fill,
# naming the first line that has one, never a value; dotenv_fill prints nothing.
nul_case() {
  local who=$1 what=$2 got err status=0
  # shellcheck disable=SC2059 # the format is the fixture
  printf "$3" > "$work/rule.env"
  got=$(dotenv_value "$work/rule.env" SVP_T 2> "$work/rule.err") || status=$?
  err=$(cat "$work/rule.err")
  if [[ $status -ne 0 && $err == *"$who"* && $err != *s3cr3t* && -z $got ]]; then
    ok "rule: $what is refused, naming $who"
  else
    fail "rule: $what: want refused naming $who, got status $status"
  fi
  printf 'SVP_T=v1\n' > "$work/rule.add"
  status=0
  dotenv_fill "$work/rule.env" "$work/rule.add" > "$work/rule.out" 2> "$work/rule.err" || status=$?
  err=$(cat "$work/rule.err")
  if [[ $status -ne 0 && $err == *"$who"* && $err != *s3cr3t* && ! -s $work/rule.out ]]; then
    ok "fill: $what is refused, naming $who"
  else
    fail "fill: $what: want refused naming $who, got status $status"
  fi
}
nul_case "rule.env:1: SVP_T" "a NUL at the start of a value" 'SVP_T=\000s3cr3t\n'
nul_case "rule.env:2: OTHER" "a NUL after a closed quote" 'SVP_T=v1\nOTHER="a"\000 s3cr3t\n'
nul_case "rule.env:1: SVP_T" "a NUL at the end of a value" 'SVP_T=s3cr3t\000\nOTHER=1\n'
nul_case "rule.env:3: the line" "a NUL in a comment" 'SVP_T=v1\n\n# s3cr3t\000x\n'
nul_case "rule.env:2: the line" "a NUL on a blank line" 'SVP_T=v1\n \000\nOTHER=1\n'
nul_case "rule.env:1: the line" "a NUL in a name" 'SVP\000_T=s3cr3t\n'
nul_case "rule.env:2: OTHER" "a NUL as the last byte, no newline" 'SVP_T=v1\nOTHER=s3cr3t\000'
nul_case "rule.env:2: OTHER" "the first of two lines with a NUL" 'SVP_T=v1\nOTHER=\000s3cr3t\nSVP_T=\000\n'
nul_case "rule.env:3: NOTE" "a NUL after a line that breaks the rule otherwise" 'SVP_T=v1\nOTHER=$HOME\nNOTE=\000s3cr3t\n'

# A missing file fails with awk's own error naming it, as before the NUL check, also under
# `set -o pipefail` (this script's, and that of init.sh, bootstrap.sh and the drills).
status=0
got=$(dotenv_value "$work/missing.env" SVP_T 2> "$work/rule.err") || status=$?
if [[ $status -ne 0 && $(cat "$work/rule.err") == *missing.env* && -z $got ]]; then
  ok "rule: a missing file fails, naming it"
else
  fail "rule: a missing file: want a failure naming it, got status $status"
fi
status=0
dotenv_fill "$work/missing.env" "$work/rule.add" > "$work/rule.out" 2> "$work/rule.err" || status=$?
if [[ $status -ne 0 && $(cat "$work/rule.err") == *missing.env* ]]; then
  ok "fill: a missing file fails, naming it"
else
  fail "fill: a missing file: want a failure naming it, got status $status"
fi

# --- init.sh: fills in SENTRY_* or stops, naming the variable, with the env file untouched. ---
cat > "$work/fake-compose" <<'EOF'
#!/usr/bin/env bash
# Stands in for `docker compose run ... glitchtip-init`: writes a test DSN and the two test tokens
# into the output directory init.sh mounts at /out.
while [ $# -gt 0 ]; do
  case $1 in -v) out=${2%:/out} ;; esac
  shift
done
printf 'dsn=http://testkey@127.0.0.1:8000/1\ntoken=testtoken\nsourcemaps_token=testtoken2\n' > "$out/credentials"
EOF
chmod 700 "$work/fake-compose"
dsn=http://testkey@glitchtip:8000/1
sentry_vars="SENTRY_DSN SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT SENTRY_API_URL SENTRY_SOURCEMAPS_TOKEN"
sentry_want="SENTRY_DSN=$dsn SENTRY_AUTH_TOKEN=testtoken SENTRY_ORG=svp SENTRY_PROJECT=svp SENTRY_API_URL=http://127.0.0.1:8000 SENTRY_SOURCEMAPS_TOKEN=testtoken2"
# sentry_values prints NAME=value for every SENTRY_* variable of an env file, as dotenv_value reads it.
sentry_values() {
  local name out=
  for name in $sentry_vars; do out="$out $name=$(dotenv_value "$1" "$name")"; done
  printf '%s' "${out# }"
}

# run_init <dir>: runs init.sh on <dir>/env; its output goes to <dir>/out.
run_init() { COMPOSE="$work/fake-compose" "$here/init.sh" "$1/env" > "$1/out" 2>&1; }
# init_fills <description> <env file lines...>: init.sh exits 0 with every SENTRY_* variable set
# as GlitchTip says, keeps the other lines, leaves mode 600, no temporary file, and a second run
# changes no byte.
init_fills() {
  local what=$1 d
  shift
  d=$(mktemp -d "$work/init.XXXXXX")
  lines "$d/orig" "$@"
  cp "$d/orig" "$d/env"
  if ! run_init "$d"; then
    fail "init.sh: $what: exited non-zero"
  elif [[ $(sentry_values "$d/env") != "$sentry_want" ]]; then
    fail "init.sh: $what: a SENTRY_* variable does not hold GlitchTip's value"
  elif ! diff <(grep -v '^SENTRY_' "$d/orig") <(grep -v '^SENTRY_' "$d/env") > /dev/null; then
    fail "init.sh: $what: other lines changed"
  elif [[ $(mode "$d/env") != 600 || -n $(leftovers "$d") ]]; then
    fail "init.sh: $what: mode is not 600 or a temporary file is left"
  else
    cp -p "$d/env" "$d/env.before"
    if run_init "$d" && cmp -s "$d/env" "$d/env.before" && grep -q 'left unchanged' "$d/out"; then
      ok "init.sh: $what: filled in, a second run changes nothing"
    else
      fail "init.sh: $what: a second run changed the env file"
    fi
  fi
}
# init_refuses <variable> <description> <env file lines...>: init.sh exits non-zero, names the
# variable, prints no value and leaves the env file as it was.
init_refuses() {
  local name=$1 what=$2 d
  shift 2
  d=$(mktemp -d "$work/init.XXXXXX")
  printf '%s\n' "$@" > "$d/env"
  chmod 600 "$d/env"
  cp -p "$d/env" "$d/env.before"
  if run_init "$d"; then
    fail "init.sh: $what: exit status 0"
  elif ! grep -q "$name" "$d/out" || grep -q -e s3cr3t -e testtoken -e testkey "$d/out"; then
    fail "init.sh: $what: the error does not name $name, or shows a value"
  elif ! cmp -s "$d/env" "$d/env.before" || [[ -n $(leftovers "$d") ]]; then
    fail "init.sh: $what: the env file changed or a temporary file is left"
  else
    ok "init.sh: $what: stops naming $name, env file untouched"
  fi
}
init_fills "no SENTRY_* variable" "OTHER=1" "# comment"
init_fills "an empty file"
init_fills 'SENTRY_DSN="" and SENTRY_AUTH_TOKEN='"''" "OTHER=1" 'SENTRY_DSN=""' "SENTRY_AUTH_TOKEN=''" "LAST=2"
init_fills "every variable already set" "SENTRY_DSN=$dsn" "SENTRY_AUTH_TOKEN=testtoken" "SENTRY_ORG=svp" \
  "SENTRY_PROJECT=svp" "SENTRY_API_URL=http://127.0.0.1:8000" "SENTRY_SOURCEMAPS_TOKEN=testtoken2"
init_refuses SENTRY_DSN 'SENTRY_DSN=${UNSET:-}' 'SENTRY_DSN=${REVIEW_UNSET_VARIABLE:-}'
init_refuses SENTRY_AUTH_TOKEN 'SENTRY_AUTH_TOKEN=${UNSET:-}' 'SENTRY_AUTH_TOKEN=${REVIEW_UNSET_VARIABLE:-}'
init_refuses "env:2:" "a set SENTRY_DSN then an indented empty one" "SENTRY_DSN=http://s3cr3t@glitchtip:8000/1" " SENTRY_DSN="
init_refuses SENTRY_DSN "SENTRY_DSN= with blanks" "SENTRY_DSN=   " "OTHER=1"
init_refuses SENTRY_DSN "SENTRY_DSN on two lines" "SENTRY_DSN=" "SENTRY_DSN="
init_refuses SENTRY_AUTH_TOKEN "a SENTRY_AUTH_TOKEN with an inline comment" "SENTRY_AUTH_TOKEN=s3cr3t # drill"
init_refuses OTHER "SENTRY_DSN= inside the quoted value of OTHER" "OTHER='s3cr3t" "SENTRY_DSN=" "suffix'"
init_refuses OTHER "SENTRY_DSN= inside a value of OTHER ending in \\'" "OTHER='s3cr3t\\'" "SENTRY_DSN=" "suffix'"
init_refuses "env:1:" "SENTRY_DSN= inside the value of OTHER-NOTE" "OTHER-NOTE='s3cr3t" "SENTRY_DSN=" "suffix'"
init_refuses OTHER "SENTRY_DSN= inside a value opened after OTHER on its line" "OTHER='a' NOTE='s3cr3t" "SENTRY_DSN=" "suffix'"
init_refuses SENTRY_DSN "CRLF SENTRY_DSN= and SENTRY_AUTH_TOKEN=" $'SENTRY_DSN=\r' $'SENTRY_AUTH_TOKEN=\r'

d=$(mktemp -d "$work/init.XXXXXX")
printf '%s\n' "SENTRY_DSN=http://otherkey@glitchtip:8000/1" > "$d/env"
cp -p "$d/env" "$d/env.before"
if run_init "$d" && grep -q 'SENTRY_DSN in .* differs' "$d/out" && ! grep -q -e otherkey -e testkey "$d/out" &&
  cmp -s <(head -n 1 "$d/env") "$d/env.before"; then
  ok "init.sh: a different SENTRY_DSN is kept and reported by name"
else
  fail "init.sh: a different SENTRY_DSN was changed or not reported"
fi

# --- make env: the same rule for every variable it generates. ---
m=$work/make
mkdir "$m"
for f in Makefile deploy go.mod go.sum tools internal; do ln -s "$repo/$f" "$m/$f"; done
run_make_env() { make --no-print-directory -C "$m" env > "$m/out" 2>&1; }
if run_make_env && [[ -f $m/.env && $(mode "$m/.env") == 600 ]] && grep -q 'wrote .env' "$m/out"; then
  ok "make env: writes a new .env, mode 600"
else
  fail "make env: could not write a new .env"
fi
cp -p "$m/.env" "$m/fresh"
names=$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$m/fresh")
empty=
for name in $names; do [[ -n $(dotenv_value "$m/fresh" "$name") ]] || empty="$empty $name"; done
if [[ -z $empty ]] && run_make_env && cmp -s "$m/.env" "$m/fresh" && grep -q 'left unchanged' "$m/out"; then
  ok "make env: every generated variable is set, a second run changes nothing"
else
  fail "make env: empty after generation:${empty:- none}, or a second run changed .env"
fi

# make_env_fills <variable> <its line>: with that one line in place of the variable's line, make
# env gives the variable a new value in the same place, keeps every other line, mode 600.
make_env_fills() {
  local name=$1 line=$2
  sed "s|^$name=.*|$line|" "$m/fresh" > "$m/.env"
  cp -p "$m/.env" "$m/.env.before"
  if ! run_make_env; then
    fail "make env: $line: exited non-zero"
  elif [[ -z $(dotenv_value "$m/.env" "$name") ]] || ! grep -q "added to .env (mode 600): $name$" "$m/out"; then
    fail "make env: $line: $name is still empty"
  elif ! diff <(grep -v "^$name=" "$m/.env.before") <(grep -v "^$name=" "$m/.env") > /dev/null ||
    [[ $(wc -l < "$m/.env") != $(wc -l < "$m/.env.before") ]]; then
    fail "make env: $line: other lines changed, or the line was not filled in place"
  elif [[ $(mode "$m/.env") != 600 || -n $(leftovers "$m") ]]; then
    fail "make env: $line: mode is not 600 or a temporary file is left"
  else
    ok "make env: $line is filled in place"
  fi
}
# make_env_refuses <variable> <description> <sed script>: make env exits non-zero, names the
# variable, prints no value and leaves .env as it was.
make_env_refuses() {
  sed "$3" "$m/fresh" > "$m/.env"
  make_env_refused "$1" "$2"
}
# make_env_refused <variable> <description>: the same check on the .env already in place.
make_env_refused() {
  local name=$1 what=$2
  cp -p "$m/.env" "$m/.env.before"
  if run_make_env; then
    fail "make env: $what: exit status 0"
  elif ! grep -q "$name" "$m/out" || grep -q s3cr3t "$m/out"; then
    fail "make env: $what: the error does not name $name, or shows a value"
  elif ! cmp -s "$m/.env" "$m/.env.before" || [[ -n $(leftovers "$m") ]]; then
    fail "make env: $what: .env changed or a temporary file is left"
  else
    ok "make env: $what: stops naming $name, .env untouched"
  fi
}
for name in SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD GLITCHTIP_SECRET_KEY \
  GLITCHTIP_ADMIN_PASSWORD GLITCHTIP_ADMIN_EMAIL; do
  make_env_fills "$name" "$name=\"\""
done
make_env_fills GLITCHTIP_SECRET_KEY "GLITCHTIP_SECRET_KEY=''"
make_env_fills SVP_USER_APP_DB_PASSWORD 'SVP_USER_APP_DB_PASSWORD=""'
make_env_refuses GLITCHTIP_SECRET_KEY '${...} in GLITCHTIP_SECRET_KEY' 's|^GLITCHTIP_SECRET_KEY=.*|GLITCHTIP_SECRET_KEY=${REVIEW_UNSET_VARIABLE:-s3cr3t}|'
make_env_refuses SVP_GLITCHTIP_APP_DB_PASSWORD "SVP_GLITCHTIP_APP_DB_PASSWORD on two lines" \
  's|^\(SVP_GLITCHTIP_APP_DB_PASSWORD=.*\)|\1\
SVP_GLITCHTIP_APP_DB_PASSWORD=|'
make_env_refuses ".env:$(($(grep -n '^GLITCHTIP_ADMIN_PASSWORD=' "$m/fresh" | cut -d : -f 1) + 1)):" \
  "an indented GLITCHTIP_ADMIN_PASSWORD line" 's|^GLITCHTIP_ADMIN_PASSWORD=.*|&\
 GLITCHTIP_ADMIN_PASSWORD=|'
make_env_refuses GLITCHTIP_ADMIN_PASSWORD "GLITCHTIP_ADMIN_PASSWORD= with blanks" \
  's|^GLITCHTIP_ADMIN_PASSWORD=.*|GLITCHTIP_ADMIN_PASSWORD=   |'
make_env_refuses SVP_VIDEO_S3_SECRET_KEY "a CRLF SVP_VIDEO_S3_SECRET_KEY line" $'s|^SVP_VIDEO_S3_SECRET_KEY=.*|&\r|'
make_env_refuses NOTE "GLITCHTIP_SECRET_KEY= inside the quoted value of NOTE" "1i\\
NOTE='s3cr3t\\
GLITCHTIP_SECRET_KEY=\\
suffix'
"
make_env_refuses NOTE "GLITCHTIP_SECRET_KEY= inside a value of NOTE ending in \\'" "1i\\
NOTE='s3cr3t\\\\'\\
GLITCHTIP_SECRET_KEY=\\
suffix'
"
make_env_refuses ".env:1:" "GLITCHTIP_SECRET_KEY= inside the value of MY-NOTE" "1i\\
MY-NOTE='s3cr3t\\
GLITCHTIP_SECRET_KEY=\\
suffix'
"
# A NUL byte (sed cannot write one portably, so printf does): awk would read the first value as
# empty and make env would replace it, the second as a, which compose refuses.
{ grep -v '^GLITCHTIP_SECRET_KEY=' "$m/fresh"; printf 'GLITCHTIP_SECRET_KEY=\000s3cr3t\n'; } > "$m/.env"
make_env_refused ".env:$(wc -l < "$m/fresh" | tr -d ' '): GLITCHTIP_SECRET_KEY" "a NUL at the start of GLITCHTIP_SECRET_KEY"
{ printf 'NOTE="a"\000 s3cr3t\n'; cat "$m/fresh"; } > "$m/.env"
make_env_refused ".env:1: NOTE" "a NUL after the closed quote of NOTE"

# --- make db-bootstrap, make test-stack and the profile check of make up, with fake commands. ---
fake=$work/fakebin
mkdir "$fake"
cat > "$fake/psql" <<'EOF'
#!/usr/bin/env bash
# Stands in for psql in bootstrap.sh: logs the database and the hashes of the two role passwords.
while [ $# -gt 0 ]; do
  case $1 in -v) case $2 in db=*) db=${2#db=} ;; esac ;; esac
  shift
done
h() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
echo "psql $db $(h "$SVP_MIGRATOR_PASSWORD") $(h "$SVP_APP_PASSWORD")" >> "$FAKE_LOG"
EOF
cat > "$fake/go" <<'EOF'
#!/usr/bin/env bash
# Stands in for go in make test-stack: logs the hashes of the two S3 secret keys `go test` gets.
# The Makefile also runs `go env GOPATH` on every make; that prints a path and logs nothing.
[ "$1" = test ] || { echo /nonexistent; exit 0; }
h() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
echo "go $(h "$SVP_TEST_S3_VIDEO_SECRET_KEY") $(h "$SVP_TEST_S3_WORKER_SECRET_KEY")" >> "$FAKE_LOG"
EOF
cat > "$fake/docker" <<'EOF'
#!/usr/bin/env bash
# Stands in for docker in make up: `compose ... ps -q <services>` prints an id when one of them is
# in FAKE_RUNNING, `compose ... run` is the fake glitchtip-init job, anything else is logged.
args=" $* "
case $args in
  *" ps -q "*)
    for s in ${args#* ps -q }; do
      case " $FAKE_RUNNING " in *" $s "*) echo fakeid && exit 0 ;; esac
    done ;;
  *" run "*) exec "$FAKE_COMPOSE" "$@" ;;
  *) echo "docker $*" >> "$FAKE_LOG" ;;
esac
EOF
chmod 700 "$fake/psql" "$fake/go" "$fake/docker"
h() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
# run_fake <make arguments...>: make in the temporary directory with the fake commands first on
# PATH; their log goes to $m/fake.log, the output to $m/out.
run_fake() {
  : > "$m/fake.log"
  FAKE_LOG=$m/fake.log FAKE_COMPOSE=$work/fake-compose PATH="$fake:$PATH" \
    make --no-print-directory -C "$m" "$@" > "$m/out" 2>&1
}

# A fixture with every role password and S3 secret key in quotes.
sed -e 's/^\(SVP_[A-Z_]*_MIGRATOR_DB_PASSWORD\)=\(.*\)/\1="\2"/' \
  -e "s/^\(SVP_[A-Z_]*_APP_DB_PASSWORD\)=\(.*\)/\1='\2'/" \
  -e 's/^\(SVP_VIDEO_S3_SECRET_KEY\)=\(.*\)/\1="\2"/' \
  -e "s/^\(SVP_MEDIA_WORKER_S3_SECRET_KEY\)=\(.*\)/\1='\2'/" "$m/fresh" > "$m/quoted"
chmod 600 "$m/quoted"
cp -p "$m/quoted" "$m/.env"
if run_make_env && cmp -s "$m/.env" "$m/quoted" && grep -q 'left unchanged' "$m/out"; then
  ok "make env: quoted values count as set, .env unchanged"
else
  fail "make env: changed a fixture whose values are all set in quotes"
fi

want=
for svc in user video engagement feed glitchtip; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  want="${want}psql svp_$svc $(h "$(dotenv_value "$m/fresh" "SVP_${upper}_MIGRATOR_DB_PASSWORD")")"
  want="$want $(h "$(dotenv_value "$m/fresh" "SVP_${upper}_APP_DB_PASSWORD")")"$'\n'
done
if run_fake db-bootstrap && [[ $(cat "$m/fake.log")$'\n' == "$want" ]]; then
  ok "make db-bootstrap: quoted passwords reach psql without their quotes"
else
  fail "make db-bootstrap: a quoted password reached psql other than unquoted"
fi
want_go="go $(h "$(dotenv_value "$m/fresh" SVP_VIDEO_S3_SECRET_KEY)") $(h "$(dotenv_value "$m/fresh" SVP_MEDIA_WORKER_S3_SECRET_KEY)")"
if run_fake test-stack PKGS=./... && [[ $(cat "$m/fake.log") == "$want_go" ]]; then
  ok "make test-stack: quoted S3 secret keys reach go test without their quotes"
else
  fail "make test-stack: a quoted S3 secret key reached go test other than unquoted"
fi

# Compose reads the quoted fixture as the plain one: `make compose-hash` (a hash of each service's
# resolved config, never a value) is the same for both, so every quoted password and S3 secret key
# reaches the services as bootstrap and test-stack read it. With one password changed, the service
# that gets it changes hash and another does not, so compose did read the env file.
if command -v docker > /dev/null; then
  # compose_hash <env file> <output>: make compose-hash OBS=lgtm with that env file as .env.
  compose_hash() { cp -p "$1" "$m/.env" && make --no-print-directory -C "$m" compose-hash OBS=lgtm > "$2" 2> "$m/out"; }
  sed 's/^\(SVP_USER_APP_DB_PASSWORD=\).*/\1changed/' "$m/fresh" > "$m/changed"
  # line <service> <output>: the service's line of a compose-hash output.
  line() { grep "^$1 " "$2"; }
  missing=
  if ! compose_hash "$m/fresh" "$work/hash.fresh" || ! compose_hash "$m/quoted" "$work/hash.quoted" ||
    ! compose_hash "$m/changed" "$work/hash.changed"; then
    fail "compose: make compose-hash failed on a fixture"
  elif for svc in user-migrate user-service video-migrate video-service engagement-migrate engagement-service \
    feed-migrate feed-service minio-init media-worker glitchtip; do
    line "$svc" "$work/hash.fresh" > /dev/null || missing="$missing $svc"
  done
  [[ -n $missing ]]; then
    fail "compose: make compose-hash OBS=lgtm has no line for:$missing"
  elif ! cmp -s "$work/hash.fresh" "$work/hash.quoted"; then
    fail "compose: reads a quoted password or S3 secret key differently from bootstrap and test-stack"
  elif [[ $(line user-service "$work/hash.changed") == "$(line user-service "$work/hash.fresh")" ||
    $(line video-service "$work/hash.changed") != "$(line video-service "$work/hash.fresh")" ]]; then
    fail "compose: a changed SVP_USER_APP_DB_PASSWORD does not change only the hash of user-service"
  else
    ok "compose: reads every quoted password and S3 secret key as bootstrap and test-stack do"
  fi
else
  echo "skip  compose: no docker CLI to compare with"
fi

# bootstrap_refuses <variable> <description> <sed script>: make db-bootstrap exits non-zero, names
# the variable, prints no value and never runs psql.
bootstrap_refuses() {
  local name=$1 what=$2
  sed "$3" "$m/quoted" > "$m/.env"
  if run_fake db-bootstrap; then
    fail "make db-bootstrap: $what: exit status 0"
  elif ! grep -q "$name" "$m/out" || grep -q -e s3cr3t -e "$(dotenv_value "$m/fresh" SVP_USER_APP_DB_PASSWORD)" "$m/out"; then
    fail "make db-bootstrap: $what: the error does not name $name, or shows a value"
  elif [[ -s $m/fake.log ]]; then
    fail "make db-bootstrap: $what: psql ran"
  else
    ok "make db-bootstrap: $what: stops naming $name before psql"
  fi
}
bootstrap_refuses SVP_GLITCHTIP_APP_DB_PASSWORD "a CRLF line of the last password" \
  $'s|^SVP_GLITCHTIP_APP_DB_PASSWORD=.*|&\r|'
bootstrap_refuses NOTE "SVP_USER_APP_DB_PASSWORD= inside the quoted value of NOTE" "1i\\
NOTE='s3cr3t\\
SVP_USER_APP_DB_PASSWORD=\\
suffix'
"
bootstrap_refuses NOTE "SVP_USER_APP_DB_PASSWORD= inside a value of NOTE ending in \\'" "1i\\
NOTE='s3cr3t\\\\'\\
SVP_USER_APP_DB_PASSWORD=\\
suffix'
"
bootstrap_refuses SVP_USER_APP_DB_PASSWORD "blanks around a quoted SVP_USER_APP_DB_PASSWORD" \
  "s|^SVP_USER_APP_DB_PASSWORD=\\(.*\\)|SVP_USER_APP_DB_PASSWORD= \\1 |"
bootstrap_refuses SVP_FEED_APP_DB_PASSWORD 'an empty SVP_FEED_APP_DB_PASSWORD=""' \
  's|^SVP_FEED_APP_DB_PASSWORD=.*|SVP_FEED_APP_DB_PASSWORD=""|'
bootstrap_refuses SVP_VIDEO_MIGRATOR_DB_PASSWORD '${...} in SVP_VIDEO_MIGRATOR_DB_PASSWORD' \
  's|^SVP_VIDEO_MIGRATOR_DB_PASSWORD=.*|SVP_VIDEO_MIGRATOR_DB_PASSWORD=${REVIEW_UNSET_VARIABLE:-s3cr3t}|'

# stack_refuses <variable> <description> <sed script>: make test-stack exits non-zero, names the
# variable and never runs go test.
stack_refuses() {
  sed "$3" "$m/quoted" > "$m/.env"
  if ! run_fake test-stack PKGS=./... && grep -q "$1" "$m/out" && ! grep -q s3cr3t "$m/out" && [[ ! -s $m/fake.log ]]; then
    ok "make test-stack: $2: stops naming $1, before go test"
  else
    fail "make test-stack: $2: did not stop naming $1 before go test"
  fi
}
stack_refuses SVP_MEDIA_WORKER_S3_SECRET_KEY "a CRLF line" $'s|^SVP_MEDIA_WORKER_S3_SECRET_KEY=.*|&\r|'
stack_refuses NOTE "SVP_VIDEO_S3_SECRET_KEY= inside a value of NOTE ending in \\'" "1i\\
NOTE='s3cr3t\\\\'\\
SVP_VIDEO_S3_SECRET_KEY=\\
suffix'
"

# up_case <up or refused> <running services> <OBS>: with those services running, make up starts the
# stack, or refuses before bootstrap and compose up and says to run make down first.
up_case() {
  local want=$1 running=$2 obs=$3 status=0
  cp -p "$m/quoted" "$m/.env"
  FAKE_RUNNING=$running run_fake up OBS="$obs" || status=$?
  if [[ $want == up ]]; then
    if [[ $status -eq 0 ]] && grep -q ' up -d --build --wait' "$m/fake.log"; then
      ok "make up OBS=$obs with [$running] running: starts"
    else
      fail "make up OBS=$obs with [$running] running: want started, got status $status"
    fi
  elif [[ $status -ne 0 ]] && grep -q "make down" "$m/out" && [[ ! -s $m/fake.log ]]; then
    ok "make up OBS=$obs with [$running] running: refused before anything ran"
  else
    fail "make up OBS=$obs with [$running] running: want refused, got status $status"
  fi
}
up_case up "gateway" ""
up_case up "gateway" off
up_case up "gateway otelcol lgtm" lgtm
up_case up "gateway kibana" elastic
up_case refused "gateway otelcol lgtm" ""
up_case refused "gateway glitchtip" off
up_case refused "gateway elasticsearch" ""
up_case refused "gateway apm-server" off
up_case refused "gateway lgtm" elastic
up_case refused "gateway kibana" lgtm

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
