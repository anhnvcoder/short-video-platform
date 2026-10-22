#!/usr/bin/env bash
# `make measure-upload`, run from web/ on the compose stack of `make up`: one upload of a ~100 MB video from Chromium
# through /upload (e2e/measure-upload.e2e.ts), then one summary: the time from the XHR's start to its load, the
# throughput, the CPU of the page's main thread while the file went up, and the time to READY; printed and written to
# test-results/measure-upload-<UTC time>.json (gitignored).
#
# The video is real and transcodes: 160 s of 1080p test pattern with noise at about 5 Mbit/s, so ~100 MB while staying
# under the 180 s the web and media-worker accept. It is made in a temporary folder, removed at the end.
#
# LOCAL LAB ONLY, like the e2e run (e2e/seed.sh resets the gateway's register rate limit in Redis db 10).
set -euo pipefail

command -v ffmpeg >/dev/null || {
  echo "measure-upload: ffmpeg not found (brew install ffmpeg)" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
video="$work/measure-upload.mp4"

echo "measure-upload: making the ~100 MB video (about a minute)"
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=160" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=160" \
  -vf "noise=alls=12:allf=t" -c:v libx264 -preset veryfast -b:v 5M -maxrate 5M -bufsize 10M -pix_fmt yuv420p \
  -c:a aac -b:a 96k -shortest -movflags +faststart "$video"

out="test-results/measure-upload-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p test-results
SVP_E2E_MEASURE_UPLOAD_FILE="$video" SVP_E2E_MEASURE_UPLOAD_OUT="$PWD/$out" \
  pnpm exec playwright test e2e/measure-upload.e2e.ts --project=chromium-publishing

echo "measure-upload:"
jq -r '"  file: \(.file_mb) MB, \(.duration_s) s 1080p",
  "  XHR start to load: \(.upload_ms) ms, \(.throughput_mb_s) MB/s",
  "  page main thread while uploading: TaskDuration \(.cpu.task_ms) ms, ScriptDuration \(.cpu.script_ms) ms (\(.cpu.task_share_pct) % of the window)",
  "  XHR start to READY: \(.ready_ms) ms"' "$out"
echo "  written to web/$out"
