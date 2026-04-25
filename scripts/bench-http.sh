#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
DURATION="${DURATION:-10s}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-64}"
RUNTIME="${RUNTIME:-auto}"
OUT_DIR="${OUT_DIR:-bench-results}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "error: wrk is required for HTTP benchmarks" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

server_args=("$PORT")
if [[ "$RUNTIME" != "auto" ]]; then
  server_args+=("$RUNTIME")
fi

zig build -Doptimize=ReleaseFast http-server -- "${server_args[@]}" &
server_pid=$!

cleanup() {
  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
result="${OUT_DIR}/http-${stamp}.txt"

{
  echo "nanoapi HTTP benchmark"
  echo "timestamp_utc=${stamp}"
  echo "git_sha=$(git rev-parse --short HEAD)"
  echo "zig_version=$(zig version)"
  echo "runtime=${RUNTIME}"
  echo "threads=${THREADS}"
  echo "connections=${CONNECTIONS}"
  echo "duration=${DURATION}"
  echo

  echo "## GET /"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "http://127.0.0.1:${PORT}/"
  echo

  echo "## GET /users/42?verbose=true"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "http://127.0.0.1:${PORT}/users/42?verbose=true"
  echo

  echo "## GET /auth"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency \
    -H "Authorization: Bearer bench-token" \
    -H "Cookie: session=bench; theme=dark" \
    "http://127.0.0.1:${PORT}/auth"
  echo

  echo "## GET /events"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "http://127.0.0.1:${PORT}/events"
  echo

  echo "## GET /file"
  wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "http://127.0.0.1:${PORT}/file"
} | tee "$result"

echo "wrote ${result}"
