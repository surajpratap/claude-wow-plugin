#!/usr/bin/env bash
# Lifecycle (replay-resistance) tests for scripts/wow-process/bus-tail.sh.
#
# Three cases:
#   1. First-arm starts at EOF — historical lines that were already on the
#      bus when the script armed must NOT be forwarded.
#   2. Inode-swap with a shorter post-swap file does NOT replay — the
#      cursor clamps down; only post-swap appends emit.
#   3. Cursor persists across re-arm — kill, restart, lines that landed
#      while the script was down emit on the next tick.
#
# Companion to tests/bus-tail-predicate.sh (which covers predicate
# correctness). This script covers cursor lifecycle.

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
  echo "FATAL: jq is required" >&2
  exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

ID="senior-developer-20260429T000000-aaaaaa"
ROLE="senior-developer"

# Wait for the deterministic arming line on stdout. Up to 2s.
wait_for_arm() {
  local out="$1"
  local i=0
  while [ $i -lt 40 ]; do
    if [ -s "$out" ] && grep -q "bus-tail-filter-armed" "$out"; then
      return 0
    fi
    sleep 0.05
    i=$((i+1))
  done
  return 1
}

# Strip the arming + inode-swap lines and any blank lines, leaving only
# what the script forwarded.
forwarded_only() {
  grep -v "bus-tail-filter-armed" "$1" 2>/dev/null \
    | grep -v "bus-tail-inode-swapped" 2>/dev/null \
    | grep -v "^$" 2>/dev/null \
    || true
}

count_lines() {
  local s="$1"
  if [ -z "$s" ]; then echo 0; else printf '%s\n' "$s" | wc -l | tr -d ' '; fi
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected $expected, got $actual)")
  fi
}

# ---------------------------------------------------------------------------
# Case 1: first-arm starts at EOF
# ---------------------------------------------------------------------------
case1() {
  local tmp; tmp="$(mktemp -d)"
  local bus="$tmp/bus.jsonl"
  local out="$tmp/out.txt"

  # Pre-populate three lines BEFORE arming.
  printf '%s\n' '{"ts":"t","from":"x","to":"*","type":"hello"}' >> "$bus"
  printf '%s\n' '{"ts":"t","from":"x","to":"*","type":"status"}' >> "$bus"
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"$ID\",\"type\":\"ack\"}" >> "$bus"

  BUS_TAIL_POLL_MS=100 "$BUS_TAIL" "$bus" "$ID" "$ROLE" > "$out" 2>/dev/null &
  local pid=$!
  if ! wait_for_arm "$out"; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    rm -rf "$tmp"
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case1 (script never armed)")
    return
  fi

  # Wait two poll intervals to let the script process its initial state.
  sleep 0.4
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local got
  got=$(forwarded_only "$out")
  assert_eq "case1 (first-arm-at-EOF)" 0 "$(count_lines "$got")"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 2: inode-swap with a shorter post-swap file does not replay
# ---------------------------------------------------------------------------
case2() {
  local tmp; tmp="$(mktemp -d)"
  local bus="$tmp/bus.jsonl"
  local out="$tmp/out.txt"
  : > "$bus"

  BUS_TAIL_POLL_MS=100 "$BUS_TAIL" "$bus" "$ID" "$ROLE" > "$out" 2>/dev/null &
  local pid=$!
  wait_for_arm "$out" || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$tmp"; FAIL=$((FAIL+1)); FAILED_CASES+=("case2 (script never armed)"); return; }

  # Append five lines, all forwardable — should produce 5 forwarded lines.
  for i in 1 2 3 4 5; do
    printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"e$i\"}" >> "$bus"
  done
  sleep 0.4

  # Now mv-replace with a SHORTER file (2 lines) — inode swap, post-swap
  # file is shorter than cursor (which is at 5).
  local replacement="$tmp/replacement.jsonl"
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"r1\"}" > "$replacement"
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"r2\"}" >> "$replacement"
  mv -f "$replacement" "$bus"
  sleep 0.4

  # Append one more line. Should be the ONLY thing forwarded after the swap.
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"post-swap\"}" >> "$bus"
  sleep 0.4

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local got total
  got=$(forwarded_only "$out")
  total=$(count_lines "$got")

  # Expected: 5 pre-swap lines + 1 post-swap line = 6. NO replay of the
  # 2-line replacement (clamped) and NO replay of the 5 originals.
  assert_eq "case2 (inode-swap clamp)" 6 "$total"

  # Specifically check the post-swap line is in the output.
  if printf '%s\n' "$got" | grep -q '"type":"post-swap"'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case2b (post-swap line forwarded)")
  fi

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Case 3: cursor persists across re-arm
# ---------------------------------------------------------------------------
case3() {
  local tmp; tmp="$(mktemp -d)"
  local bus="$tmp/bus.jsonl"
  local out1="$tmp/out1.txt"
  local out2="$tmp/out2.txt"
  : > "$bus"

  BUS_TAIL_POLL_MS=100 "$BUS_TAIL" "$bus" "$ID" "$ROLE" > "$out1" 2>/dev/null &
  local pid=$!
  wait_for_arm "$out1" || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$tmp"; FAIL=$((FAIL+1)); FAILED_CASES+=("case3 (first arm failed)"); return; }

  # Emit three lines, observe forwarded.
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"a1\"}" >> "$bus"
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"a2\"}" >> "$bus"
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"a3\"}" >> "$bus"
  sleep 0.4

  # Kill the first arm — cursor should now be at 3.
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local first_round
  first_round=$(forwarded_only "$out1")
  assert_eq "case3a (first round forwarded 3)" 3 "$(count_lines "$first_round")"

  # Append two more lines while the script is down.
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"b1\"}" >> "$bus"
  printf '%s\n' "{\"ts\":\"t\",\"from\":\"x\",\"to\":\"*\",\"type\":\"b2\"}" >> "$bus"

  # Re-arm. Should resume from cursor (3), forward the 2 new lines.
  BUS_TAIL_POLL_MS=100 "$BUS_TAIL" "$bus" "$ID" "$ROLE" > "$out2" 2>/dev/null &
  pid=$!
  wait_for_arm "$out2" || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$tmp"; FAIL=$((FAIL+1)); FAILED_CASES+=("case3 (re-arm failed)"); return; }
  sleep 0.4
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  local second_round
  second_round=$(forwarded_only "$out2")
  assert_eq "case3b (re-arm forwarded 2)" 2 "$(count_lines "$second_round")"

  if printf '%s\n' "$second_round" | grep -q '"type":"b1"'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3c (b1 was forwarded after re-arm)")
  fi
  if printf '%s\n' "$second_round" | grep -q '"type":"b2"'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3d (b2 was forwarded after re-arm)")
  fi
  if printf '%s\n' "$second_round" | grep -q '"type":"a'; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("case3e (no replay of a* lines on re-arm)")
  else
    PASS=$((PASS+1))
  fi

  rm -rf "$tmp"
}

case1
case2
case3

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
