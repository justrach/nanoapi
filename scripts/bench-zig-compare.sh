#!/bin/sh
set -eu

# Compare the checked-in pre-0.17 baseline (HEAD) with the current working tree.
# The benchmark emits results on stderr, so capture both streams deliberately.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASELINE="$ROOT/bench-results/.zig-compare-baseline"
RUNS=${RUNS:-5}
ZIG16_VERSION=${ZIG16_VERSION:-0.16.0}
ZIG17_VERSION=${ZIG17_VERSION:-0.17.0-dev.813+2153f8143}

cleanup() {
    rm -rf "$BASELINE"
}
trap cleanup EXIT INT TERM

rm -rf "$BASELINE"
mkdir -p "$BASELINE"
git -C "$ROOT" archive HEAD | tar -x -C "$BASELINE"

run_bench() {
    label=$1
    dir=$2
    zig_version=$3
    output=$4

    printf '\n=== %s (%s), %s runs ===\n' "$label" "$zig_version" "$RUNS"
    i=1
    while [ "$i" -le "$RUNS" ]; do
        printf '%s run %s\n' "$label" "$i"
        (cd "$dir" && zigup run "$zig_version" build -Doptimize=ReleaseFast bench) 2>&1 |
            awk '/^nano / { print }' | tee -a "$output"
        i=$((i + 1))
    done
}

: > "$ROOT/bench-results/zig-compare.txt"
run_bench "baseline HEAD" "$BASELINE" "$ZIG16_VERSION" "$ROOT/bench-results/zig-compare.txt"
run_bench "current tree" "$ROOT" "$ZIG17_VERSION" "$ROOT/bench-results/zig-compare.txt"

printf '\nRaw results saved to bench-results/zig-compare.txt\n'
printf 'This compares the pre-migration HEAD with the current tree; it is not a compiler-only A/B test.\n'
