#!/usr/bin/env bash
# End-to-end Linux io_uring bench for nanoapi using Apple `container` (or any
# OCI runtime that speaks the same CLI: docker, podman). Builds a static
# aarch64-linux-musl binary from the host, packages it with wrk into an
# Alpine image, runs the server with the io_uring runtime, and drives a
# fixed wrk suite from inside the same container against 127.0.0.1.
#
# Requirements: zig 0.16+, Apple `container` 0.11+ (or set RUNTIME=docker).
# Run from the repo root: ./bench/linux/run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_DIR="$REPO_ROOT/bench/linux"
RUNTIME="${RUNTIME:-container}"
TARGET="${TARGET:-aarch64-linux-musl}"
IMAGE="${IMAGE:-nano-bench:latest}"
NAME="${NAME:-nano-bench}"
CPUS="${CPUS:-8}"
MEM="${MEM:-4096M}"
WORKERS="${WORKERS:-4}"
DURATION="${DURATION:-15s}"

cd "$REPO_ROOT"

echo "==> cross-compiling http-server for $TARGET"
zig build -Doptimize=ReleaseFast -Dtarget="$TARGET" http-server || true
BIN=$(find .zig-cache/o -type f -name nano_http_bench -newer build.zig | head -1)
[ -z "$BIN" ] && { echo "build failed"; exit 1; }
cp "$BIN" "$BENCH_DIR/nano_http_bench"

echo "==> building OCI image"
"$RUNTIME" build -t "$IMAGE" -f "$BENCH_DIR/Containerfile" "$BENCH_DIR"

echo "==> starting server (runtime=auto, $WORKERS workers, $CPUS vCPU)"
"$RUNTIME" rm -f "$NAME" 2>/dev/null || true
"$RUNTIME" run -d --name "$NAME" --rm --cpus "$CPUS" -m "$MEM" \
    --mount "type=bind,source=$BENCH_DIR,target=/scripts,readonly" \
    "$IMAGE" /usr/local/bin/nano_http_bench 8080 auto "$WORKERS"
sleep 1
"$RUNTIME" logs "$NAME" 2>&1 | head -3

URL=http://127.0.0.1:8080
EXEC="$RUNTIME exec $NAME"

echo "==> warmup"
$EXEC wrk -t4 -c64 -d5s "$URL/" >/dev/null

echo
echo "=== GET /  (1 conn, RTT-bound) ==="
$EXEC wrk -t1 -c1 -d10s --latency "$URL/"

echo
echo "=== GET /  (256 conns) ==="
$EXEC wrk -t4 -c256 -d"$DURATION" --latency "$URL/"

echo
echo "=== GET /  pipelined 16x  (64 conns) ==="
$EXEC wrk -t4 -c64 -d"$DURATION" --latency -s /scripts/pipeline.lua "$URL/"

echo
echo "=== POST /users (typed body, 64 conns) ==="
$EXEC wrk -t4 -c64 -d"$DURATION" --latency -s /scripts/post-users.lua "$URL/users"

echo
echo "=== GET /auth (authorized path, 64 conns) ==="
$EXEC wrk -t4 -c64 -d"$DURATION" --latency -s /scripts/auth-headers.lua "$URL/auth"

echo
echo "==> stopping"
"$RUNTIME" stop "$NAME"
