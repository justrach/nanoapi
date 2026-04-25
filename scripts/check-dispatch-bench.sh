#!/usr/bin/env bash
set -euo pipefail

ITERATIONS="${ITERATIONS:-1000000}"
WARMUP="${WARMUP:-100000}"
REPEAT="${REPEAT:-5}"
STATIC_MAX_NS="${STATIC_MAX_NS:-40}"
TYPED_MAX_NS="${TYPED_MAX_NS:-140}"
CORE_MAX_NS="${CORE_MAX_NS:-80}"

output="$(
  zig build -Doptimize=ReleaseFast bench -- "$ITERATIONS" \
    --warmup "$WARMUP" \
    --repeat "$REPEAT" \
    --format=json 2>&1
)"

printf '%s\n' "$output"

extract_avg() {
  local name="$1"
  printf '%s\n' "$output" | awk -v name="$name" '
    index($0, "\"name\":\"" name "\"") > 0 {
      if (match($0, /"avg_ns_per_op":[0-9.]+/)) {
        value = substr($0, RSTART, RLENGTH)
        sub(/"avg_ns_per_op":/, "", value)
        print value
        exit
      }
    }
  '
}

check_max() {
  local label="$1"
  local value="$2"
  local max="$3"
  awk -v label="$label" -v value="$value" -v max="$max" '
    BEGIN {
      if (value == "") {
        printf("missing benchmark result for %s\n", label) > "/dev/stderr"
        exit 2
      }
      if (value + 0 > max + 0) {
        printf("%s regression: %.3f ns/op > %.3f ns/op\n", label, value, max) > "/dev/stderr"
        exit 1
      }
      printf("%s ok: %.3f ns/op <= %.3f ns/op\n", label, value, max)
    }
  '
}

check_max "nano dispatch static" "$(extract_avg "nano dispatch static")" "$STATIC_MAX_NS"
check_max "nano dispatch typed param+query" "$(extract_avg "nano dispatch typed param+query")" "$TYPED_MAX_NS"
check_max "turboapi-core route lookup" "$(extract_avg "turboapi-core route lookup")" "$CORE_MAX_NS"
