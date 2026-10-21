#!/usr/bin/env bash
# last-success.sh: reads on stdin the JSON of `GET /repos/{owner}/{repo}/actions/workflows/images.yml/runs` (filtered
# to branch main, event push, status success) and prints the head_sha of the newest run that really is a successful
# push run on main; prints nothing when there is none or the JSON cannot be read
# (docs/adr/0015-cicd-devsecops-stage5.md, section 3). Nothing printed means "no base": changed-services.sh then builds
# all six, so a bad answer from the API can only make a run build too much, never too little. Always exits 0.
set -uo pipefail

sha=$(jq -r '
  [.workflow_runs[]?
    | select(.conclusion == "success" and .event == "push" and .head_branch == "main")
    | .head_sha][0] // ""' 2>/dev/null) || sha=
if [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
  echo "$sha"
else
  echo "no successful push run of images.yml on main in the API answer" >&2
fi
