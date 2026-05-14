#!/usr/bin/env bash
# Six-case assertion suite for scripts/wow-process/bus-tail.sh.
#
# For each case: start bus-tail.sh tailing an empty temp file, wait for the
# arming line, append a synthetic bus line, then assert whether that line
# was forwarded (kept) or dropped.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUS_TAIL="$REPO_ROOT/scripts/wow-process/bus-tail.sh"

if [ ! -x "$BUS_TAIL" ]; then
  if [ -f "$BUS_TAIL" ]; then
    chmod +x "$BUS_TAIL"
  else
    echo "FATAL: $BUS_TAIL not found" >&2
    exit 2
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required for bus-tail.sh tests" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

# Run one case. Args:
#   $1: case name
#   $2: agent id passed to bus-tail.sh
#   $3: role prefix passed to bus-tail.sh
#   $4: synthetic bus line (raw, can be malformed)
#   $5: "kept" or "dropped"
run_case() {
  local name="$1"
  local id="$2"
  local role="$3"
  local line="$4"
  local expect="$5"

  local tmpdir
  tmpdir="$(mktemp -d)"
  local bus="$tmpdir/bus.jsonl"
  local out="$tmpdir/out.txt"
  : > "$bus"

  "$BUS_TAIL" "$bus" "$id" "$role" > "$out" 2>/dev/null &
  local pid=$!

  # Wait up to 2s for the arming line.
  local i=0
  while [ $i -lt 40 ]; do
    if [ -s "$out" ] && grep -q "bus-tail-filter-armed" "$out"; then
      break
    fi
    sleep 0.05
    i=$((i+1))
  done

  if ! grep -q "bus-tail-filter-armed" "$out"; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$tmpdir"
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (script never armed)")
    return
  fi

  # Append the synthetic line and give jq time to flush it.
  printf '%s\n' "$line" >> "$bus"
  sleep 0.5

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local forwarded
  forwarded="$(grep -v "bus-tail-filter-armed" "$out" || true)"

  case "$expect" in
    kept)
      if [ -z "$forwarded" ]; then
        FAIL=$((FAIL+1))
        FAILED_CASES+=("$name (expected kept, got nothing)")
      else
        PASS=$((PASS+1))
      fi
      ;;
    dropped)
      if [ -n "$forwarded" ]; then
        FAIL=$((FAIL+1))
        FAILED_CASES+=("$name (expected dropped, got: $forwarded)")
      else
        PASS=$((PASS+1))
      fi
      ;;
    *)
      FAIL=$((FAIL+1))
      FAILED_CASES+=("$name (bad expectation: $expect)")
      ;;
  esac

  rm -rf "$tmpdir"
}

ID="senior-developer-20260429T000000-aaaaaa"
ROLE="senior-developer"
ROLE_GLOB="senior-developer-*"

run_case "broadcast (to:*)" "$ID" "$ROLE" \
  '{"ts":"t","from":"manager-x","to":"*","type":"hello"}' \
  kept

run_case "exact agent id" "$ID" "$ROLE" \
  "{\"ts\":\"t\",\"from\":\"manager-x\",\"to\":\"$ID\",\"type\":\"ack\"}" \
  kept

run_case "role-glob" "$ID" "$ROLE" \
  "{\"ts\":\"t\",\"from\":\"manager-x\",\"to\":\"$ROLE_GLOB\",\"type\":\"story-created\"}" \
  kept

run_case "self-echo dropped" "$ID" "$ROLE" \
  "{\"ts\":\"t\",\"from\":\"$ID\",\"to\":\"*\",\"type\":\"hello\"}" \
  dropped

run_case "other role dropped" "$ID" "$ROLE" \
  '{"ts":"t","from":"manager-x","to":"tester-*","type":"nudge"}' \
  dropped

run_case "malformed JSON dropped" "$ID" "$ROLE" \
  'this is not json {{{' \
  dropped

echo
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi
exit 0
