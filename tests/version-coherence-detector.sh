#!/usr/bin/env bash
# Story 057 — plugin update-availability check + cross-agent hello-mismatch
# detector.
#
# Two halves:
#   Cases 1-3: scripts/check-plugin-updates.sh helper, with gh mocked via
#              PATH-overridden tmp shim emitting canned JSON.
#   Cases 4-7: M's hello-handler logic, tested via a `simulate_m_hello`
#              function that mirrors the prompt's pseudocode 1:1. (M's
#              handler isn't extracted to a script, so the simulator
#              documents that the prompt logic is unambiguous + testable.)
#
# Cases:
# 1. Helper: local matches latest → no stdout
# 2. Helper: local < latest → "update-available <X> <Y> <URL>" on stdout
# 3. Helper: gh failure → empty stdout, non-empty stderr, exit 0
# 4. Hello-detector: peer matches local → no nudge
# 5. Hello-detector: peer < local → exactly one nudge to peer's agent ID
# 6. Hello-detector: same peer drifts twice → only one nudge total (set semantic)
# 7. Hello-detector: object payload {note: "...Plugin vX..."} also extracts

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

assert_contains() {
  local name="$1"; local needle="$2"; local haystack="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle': '$haystack')") ;;
  esac
}

assert_nonempty() {
  local name="$1"; local actual="$2"
  if [ -n "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected non-empty, got empty)")
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
# check-plugin-updates.sh is a source-repo project tool (NOT bundled in plugin/scripts/).
HELPER="$SOURCE_ROOT/scripts/check-plugin-updates.sh"

# -----------------------------------------------------------------------------
# Helper-test rig: build a tmp gh shim that emits canned JSON on
# `gh release view --repo X --json ...`. Set PATH so `which gh` finds it.
# -----------------------------------------------------------------------------
mk_gh_shim() {
  local mode="$1"      # "match" | "newer" | "fail"
  local local_v="$2"
  local latest_v="$3"
  local url="$4"
  local dir
  dir=$(mktemp -d)
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
# canned shim for test
case "\$1 \$2" in
  "release view")
    case "$mode" in
      match|newer)
        echo '{"tagName":"v$latest_v","url":"$url"}'
        exit 0
        ;;
      fail)
        echo "gh: stub failure (mode=fail)" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    # other gh subcommands — pass through silently
    exit 0
    ;;
esac
EOF
  chmod +x "$dir/gh"
  # Build a minimal repo root with a plugin.json
  mkdir -p "$dir/.claude-plugin"
  printf '{"version": "%s"}\n' "$local_v" > "$dir/.claude-plugin/plugin.json"
  echo "$dir"
}

run_helper() {
  local rig_dir="$1"
  local stdout_file stderr_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  PATH="$rig_dir:$PATH" ROOT="$rig_dir" bash "$HELPER" "fake-org/fake-repo" \
    > "$stdout_file" 2> "$stderr_file"
  local rc=$?
  local stdout stderr
  stdout=$(cat "$stdout_file")
  stderr=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
  printf '%s\n---STDERR---\n%s\n---RC---\n%s\n' "$stdout" "$stderr" "$rc"
}

extract_stdout() { echo "$1" | awk '/---STDERR---/{exit} {print}'; }
extract_stderr() { echo "$1" | awk '/---STDERR---/{flag=1;next} /---RC---/{exit} flag{print}'; }
extract_rc()     { echo "$1" | awk '/---RC---/{flag=1;next} flag{print; exit}'; }

# -----------------------------------------------------------------------------
# Case 1: local matches latest → no stdout
# -----------------------------------------------------------------------------
RIG=$(mk_gh_shim match "1.2.3" "1.2.3" "https://example.com/release")
R1=$(run_helper "$RIG")
assert_eq "case-1-helper-match-no-stdout" "" "$(extract_stdout "$R1")"
assert_eq "case-1-helper-match-rc-0" "0" "$(extract_rc "$R1")"
rm -rf "$RIG"

# -----------------------------------------------------------------------------
# Case 2: local < latest → "update-available <X> <Y> <URL>" on stdout
# -----------------------------------------------------------------------------
RIG=$(mk_gh_shim newer "1.2.3" "2.0.0" "https://github.com/fake-org/fake-repo/releases/tag/v2.0.0")
R2=$(run_helper "$RIG")
OUT2=$(extract_stdout "$R2")
assert_eq "case-2-helper-newer-stdout-line" \
  "update-available 1.2.3 2.0.0 https://github.com/fake-org/fake-repo/releases/tag/v2.0.0" \
  "$OUT2"
assert_eq "case-2-helper-newer-rc-0" "0" "$(extract_rc "$R2")"
rm -rf "$RIG"

# -----------------------------------------------------------------------------
# Case 3: gh failure → empty stdout, non-empty stderr, exit 0
# -----------------------------------------------------------------------------
RIG=$(mk_gh_shim fail "1.2.3" "" "")
R3=$(run_helper "$RIG")
assert_eq "case-3-helper-failure-no-stdout" "" "$(extract_stdout "$R3")"
assert_nonempty "case-3-helper-failure-stderr-warns" "$(extract_stderr "$R3")"
assert_eq "case-3-helper-failure-rc-0" "0" "$(extract_rc "$R3")"
rm -rf "$RIG"

# -----------------------------------------------------------------------------
# Hello-detector simulator. Mirrors commands/manager.md `hello` handler:
#   1. Coerce payload to string (use .note if object).
#   2. Regex extract Plugin v(X.Y.Z); skip if no match.
#   3. If peer_version != local_version AND agent_id not in NUDGED set → nudge.
#
# State: NUDGED_AGENTS is a sorted-deduped string of agent IDs.
# Echoes one of: "no-version-extracted" | "no-nudge-match" | "no-nudge-already-warned"
#                | "nudge:<agent-id>:peer=<peer-v>:local=<local-v>"
# -----------------------------------------------------------------------------
NUDGED_AGENTS=""

simulate_m_hello() {
  local payload_json="$1"   # raw JSON value (string OR object)
  local agent_id="$2"
  local local_v="$3"

  # Step 1: coerce to string
  local s
  s=$(echo "$payload_json" | jq -r 'if type == "string" then . elif type == "object" and has("note") then .note else "" end')
  if [ -z "$s" ]; then
    echo "no-version-extracted"
    return 0
  fi

  # Step 2: regex extract
  local peer_v
  if [[ "$s" =~ Plugin\ v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    peer_v="${BASH_REMATCH[1]}"
  else
    echo "no-version-extracted"
    return 0
  fi

  # Step 3: drift check + set semantic
  if [ "$peer_v" = "$local_v" ]; then
    echo "no-nudge-match"
    return 0
  fi
  if echo "$NUDGED_AGENTS" | tr ',' '\n' | grep -qx "$agent_id"; then
    echo "no-nudge-already-warned"
    return 0
  fi
  if [ -z "$NUDGED_AGENTS" ]; then
    NUDGED_AGENTS="$agent_id"
  else
    NUDGED_AGENTS="$NUDGED_AGENTS,$agent_id"
  fi
  echo "nudge:$agent_id:peer=$peer_v:local=$local_v"
}

# -----------------------------------------------------------------------------
# Case 4: peer hello matches local → no nudge
# -----------------------------------------------------------------------------
NUDGED_AGENTS=""
PAYLOAD='"Senior Developer online. Plugin v2.33.7. Standing by."'
R4=$(simulate_m_hello "$PAYLOAD" "senior-developer-A" "2.33.7")
assert_eq "case-4-hello-match-no-nudge" "no-nudge-match" "$R4"

# -----------------------------------------------------------------------------
# Case 5: peer hello < local → exactly one nudge to peer's agent ID
# -----------------------------------------------------------------------------
NUDGED_AGENTS=""
PAYLOAD='"Senior Developer online. Plugin v2.33.6. Standing by."'
R5=$(simulate_m_hello "$PAYLOAD" "senior-developer-B" "2.33.7")
assert_eq "case-5-hello-drift-nudges-once" "nudge:senior-developer-B:peer=2.33.6:local=2.33.7" "$R5"
# Note: NUDGED_AGENTS is updated inside the function but we ran it in a
# subshell via $(), so the parent's set is unchanged. Case 6 handles that.

# -----------------------------------------------------------------------------
# Case 6: same peer drifts twice → only one nudge total (set semantic)
# We need to update state ACROSS calls, so use direct calls (not subshells).
# -----------------------------------------------------------------------------
NUDGED_AGENTS=""
PAYLOAD='"Senior Developer online. Plugin v2.33.6. Standing by."'
# First call (direct, not subshell) — capture stdout via temp file
TMPF=$(mktemp)
simulate_m_hello "$PAYLOAD" "senior-developer-C" "2.33.7" > "$TMPF"
R6_FIRST=$(cat "$TMPF")
simulate_m_hello "$PAYLOAD" "senior-developer-C" "2.33.7" > "$TMPF"
R6_SECOND=$(cat "$TMPF")
rm -f "$TMPF"
assert_eq "case-6-first-call-nudges" "nudge:senior-developer-C:peer=2.33.6:local=2.33.7" "$R6_FIRST"
assert_eq "case-6-second-call-suppressed" "no-nudge-already-warned" "$R6_SECOND"

# -----------------------------------------------------------------------------
# Case 7: payload as object {note: "...Plugin v..."} also extracts
# -----------------------------------------------------------------------------
NUDGED_AGENTS=""
PAYLOAD='{"note": "Pair Programmer online. Plugin v2.33.6. Exclude count: 15."}'
R7=$(simulate_m_hello "$PAYLOAD" "pair-programmer-D" "2.33.7")
assert_eq "case-7-object-payload-extracts" "nudge:pair-programmer-D:peer=2.33.6:local=2.33.7" "$R7"

# Bonus: payload with no version-bearing substring → no-version-extracted (regression guard for soft contract)
NUDGED_AGENTS=""
PAYLOAD='"legacy peer hello with no plugin version"'
R8=$(simulate_m_hello "$PAYLOAD" "legacy-E" "2.33.7")
assert_eq "case-7b-legacy-payload-no-version-extracted" "no-version-extracted" "$R8"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "version-coherence-detector: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
