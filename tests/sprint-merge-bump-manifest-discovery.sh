#!/usr/bin/env bash
# Story 056 — sprint-merge-bump.sh manifest auto-discovery.
#
# Asserts _discover_manifest picks the in-progress sprint manifest, falls
# back to lexicographic-tail when no sprint is active, fails loud (exit 2)
# on multi-active, and honors WOW_SPRINT_MANIFEST override.
#
# Cases:
# 1. single in-progress manifest → picked
# 2. multiple manifests, only one in-progress → in-progress one picked
#    (NOT alphabetically first — proves the fix)
# 3. zero in-progress, multiple complete → tail -1 fallback (most recent)
# 4. two manifests both in-progress → exit 2 + stderr lists both
# 5. WOW_SPRINT_MANIFEST env override → that path returned (override wins)

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

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/sprint-merge-bump.sh"

if [ ! -f "$WRAPPER" ]; then
  echo "FAIL: wrapper not found at $WRAPPER" >&2
  exit 1
fi

# Fixture builder: creates a temp dir with N sprint manifest files and
# returns the temp path on stdout. Each arg is "name:status".
mk_fixture() {
  local tdir
  tdir=$(mktemp -d)
  mkdir -p "$tdir/implementations/sprints"
  local arg name mstatus
  for arg in "$@"; do
    name="${arg%%:*}"
    mstatus="${arg##*:}"
    mkdir -p "$tdir/implementations/sprints/$name"
    printf '{"sprint_id":"%s","status":"%s","items":[]}\n' "$name" "$mstatus" \
      > "$tdir/implementations/sprints/$name/manifest.json"
  done
  echo "$tdir"
}

# Run _discover_manifest under a given ROOT + optional override.
# Captures stdout + stderr + rc. Echoes "rc|stdout|stderr".
run_discover() {
  local root="$1"
  local override="${2:-}"
  local out err rc
  out=$(
    if [ -n "$override" ]; then
      WOW_SPRINT_MANIFEST="$override" ROOT="$root" bash -c "
        source '$WRAPPER'
        _discover_manifest
      " 2> >(err=$(cat); typeset -p err >&2)
    else
      unset WOW_SPRINT_MANIFEST 2>/dev/null
      ROOT="$root" bash -c "
        source '$WRAPPER'
        _discover_manifest
      " 2> >(err=$(cat); typeset -p err >&2)
    fi
    echo "RC=$?"
  )
  echo "$out"
}

# Simpler runner: split stdout / stderr / rc cleanly without subshell juggling.
run_disco_simple() {
  local root="$1"
  local override="${2:-}"
  local stdout_file stderr_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  if [ -n "$override" ]; then
    WOW_SPRINT_MANIFEST="$override" ROOT="$root" bash -c "
      source '$WRAPPER'
      _discover_manifest
    " > "$stdout_file" 2> "$stderr_file"
  else
    unset WOW_SPRINT_MANIFEST
    ROOT="$root" bash -c "
      source '$WRAPPER'
      _discover_manifest
    " > "$stdout_file" 2> "$stderr_file"
  fi
  local rc=$?
  local stdout stderr
  stdout=$(cat "$stdout_file")
  stderr=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
  # Output as 3 lines: stdout / stderr / rc, separated by null-ish marker.
  printf '%s\n---STDERR---\n%s\n---RC---\n%s\n' "$stdout" "$stderr" "$rc"
}

extract_stdout()   { echo "$1" | awk '/---STDERR---/{exit} {print}'; }
extract_stderr()   { echo "$1" | awk '/---STDERR---/{flag=1;next} /---RC---/{exit} flag{print}'; }
extract_rc()       { echo "$1" | awk '/---RC---/{flag=1;next} flag{print; exit}'; }

# -----------------------------------------------------------------------------
# Case 1: single in-progress manifest → picked
# -----------------------------------------------------------------------------
T1=$(mk_fixture "2026-05-03-active:in-progress")
R1=$(run_disco_simple "$T1")
OUT1=$(extract_stdout "$R1")
assert_eq "case-1-single-in-progress-picked" \
  "$T1/implementations/sprints/2026-05-03-active/manifest.json" \
  "$OUT1"
rm -rf "$T1"

# -----------------------------------------------------------------------------
# Case 2: multiple manifests, only one in-progress → in-progress picked
# (proves alphabetical-first is bypassed)
# -----------------------------------------------------------------------------
T2=$(mk_fixture \
  "2026-01-aaa:complete" \
  "2026-02-bbb:in-progress" \
  "2026-03-ccc:complete")
R2=$(run_disco_simple "$T2")
OUT2=$(extract_stdout "$R2")
assert_eq "case-2-multi-only-one-in-progress-picked" \
  "$T2/implementations/sprints/2026-02-bbb/manifest.json" \
  "$OUT2"
# Sanity: explicitly assert it's NOT the alphabetical first (aaa).
case "$OUT2" in
  *2026-01-aaa*) ALPHA_FIRST="picked"; ;;
  *) ALPHA_FIRST="bypassed" ;;
esac
assert_eq "case-2-alphabetical-first-bypassed" "bypassed" "$ALPHA_FIRST"
rm -rf "$T2"

# -----------------------------------------------------------------------------
# Case 3: zero in-progress, multiple complete → tail -1 fallback (most recent)
# -----------------------------------------------------------------------------
T3=$(mk_fixture \
  "2026-01-aaa:complete" \
  "2026-02-bbb:complete" \
  "2026-03-ccc:complete")
R3=$(run_disco_simple "$T3")
OUT3=$(extract_stdout "$R3")
assert_eq "case-3-no-in-progress-tail-fallback" \
  "$T3/implementations/sprints/2026-03-ccc/manifest.json" \
  "$OUT3"
rm -rf "$T3"

# -----------------------------------------------------------------------------
# Case 4: two manifests both in-progress → exit 2 + stderr lists both
# -----------------------------------------------------------------------------
T4=$(mk_fixture \
  "2026-04-aaa:in-progress" \
  "2026-04-bbb:in-progress" \
  "2026-04-ccc:complete")
R4=$(run_disco_simple "$T4")
RC4=$(extract_rc "$R4")
ERR4=$(extract_stderr "$R4")
assert_eq "case-4-multi-active-exits-2" "2" "$RC4"
assert_contains "case-4-stderr-mentions-aaa" "2026-04-aaa" "$ERR4"
assert_contains "case-4-stderr-mentions-bbb" "2026-04-bbb" "$ERR4"
assert_contains "case-4-stderr-explains-violation" "MULTIPLE in-progress" "$ERR4"
rm -rf "$T4"

# -----------------------------------------------------------------------------
# Case 5: WOW_SPRINT_MANIFEST env override → that path returned (override wins)
# -----------------------------------------------------------------------------
T5=$(mk_fixture "2026-05-real:in-progress")  # Real manifest exists
OVERRIDE_PATH="/tmp/totally-fake-override-$$.json"  # Doesn't exist
R5=$(run_disco_simple "$T5" "$OVERRIDE_PATH")
OUT5=$(extract_stdout "$R5")
assert_eq "case-5-env-override-wins" "$OVERRIDE_PATH" "$OUT5"
rm -rf "$T5"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "sprint-merge-bump-manifest-discovery: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
