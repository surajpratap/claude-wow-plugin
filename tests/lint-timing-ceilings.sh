#!/usr/bin/env bash
# Story 170 — generous-ceiling lint (the false-FAIL twin of 169's false-PASS
# guard). Reuses 169's PLUGIN_ROOT-from-$0 + tests/*.sh file-walk pattern.
#
# === RULE (single source of truth) ===
# A behavioral timing test polls with `wait_for <file> <pat> <count> <ceiling>`
# (the fixed 4-positional signature; the function returns the INSTANT the
# predicate holds, so a generous ceiling costs nothing on the happy path). A
# TIGHT ceiling times out under load and false-FAILs (FINDING-46). This lint
# FLOORS every literal-integer `wait_for` ceiling at WOW_MIN_WAIT_CEILING_S
# (default 30):
#
#   For each tests/*.sh file containing `wait_for`, for each `wait_for ` CALL
#   SITE line: the ceiling is the LAST positional token (NOT $4 — a spaced
#   quoted <pat> like 'recovered: test/repo' shifts $4 to the count; the ceiling
#   is physically the last arg regardless of how the middle pattern splits).
#   If that token is a literal integer < floor AND the raw line carries no
#   inline allow-marker (`# generous` / `# settle`) -> FAIL:
#     <file>:<lineno> wait_for ceiling <n> below floor <floor> ...
#   A non-integer ceiling (a $var) is SKIPPED (can't statically floor).
#
# Scope is ONLY the wait_for last-arg ceiling — there is NO bare-`sleep` clause
# (M correction: the tree has ~20 legitimate `sleep N` producer runs that are
# NOT readiness waits). The lint MUST exit 0 on the unmodified real tree (the
# real ceilings are 30/40/60s — all >= floor).
#
# bash-3.2-safe: case globs + set -- word-splitting, no \d/PCRE.
#
# The lint IS its own test (169 style): the fixtures under
# tests/fixtures/timing/{tight,generous,marked,spaced}/ self-assert all four
# discriminations. A presence-grep for the file is NOT enough.
#
# RED-WITHOUT: patch .red-without/timing-floor.patch -> tight ceiling 20 flagged

set -u

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$PLUGIN_ROOT/tests/fixtures/timing"
FLOOR="${WOW_MIN_WAIT_CEILING_S:-30}"

PASS=0
FAIL=0
FAILED=()
pass() { PASS=$((PASS + 1)); }
note_fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }
log() { printf 'lint-timing-ceilings: %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# lint_file <abspath>
#   Echoes one `<basename>:<lineno> wait_for ceiling <n> below floor <floor> ...`
#   line per offending call site; emits nothing for a clean file. Returns 0.
# --- LINT-CORE-START (timing-floor.patch lowers the floor so tight stops flagging) ---
lint_file() {
  local file="$1" base lineno=0 raw stripped ceiling
  base="$(basename "$file")"
  while IFS= read -r raw; do
    lineno=$((lineno + 1))
    # Only `wait_for ` CALL SITES — `wait_for_arm`/`wait_for_bridge`/etc. are
    # different helpers (the char after `wait_for` is `_`, not whitespace).
    case "$raw" in
      *wait_for[[:space:]]*) ;;
      *) continue ;;
    esac
    # Strip a trailing `# ...` comment for token parsing (KEEP raw for the
    # allow-marker check), then strip any shell operator/continuation that
    # follows the call so the ceiling is the call's LAST positional arg.
    stripped="${raw%%#*}"
    stripped="${stripped%%||*}"
    stripped="${stripped%%&&*}"
    stripped="${stripped%%;*}"
    # shellcheck disable=SC2086
    set -- $stripped
    [ "$#" -ge 1 ] || continue
    eval "ceiling=\${$#}"
    # Only a literal integer can be floored; a $var ceiling is skipped.
    case "$ceiling" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$ceiling" -lt "$FLOOR" ]; then
      # Allow-marker on the RAW line documents an intentional tight ceiling.
      case "$raw" in
        *"# generous"*|*"# settle"*) continue ;;
      esac
      printf '%s:%d wait_for ceiling %s below floor %s (use a generous ceiling, or annotate '\''# generous'\'' if intentional)\n' \
        "$base" "$lineno" "$ceiling" "$FLOOR"
    fi
  done < "$file"
}
# --- LINT-CORE-END ---

# ===========================================================================
# Fixture self-asserts — always run (incl. selftest mode). Assert ALL FOUR
# discriminations behaviorally (flag tight, pass generous, respect marker,
# pass spaced) — a presence-grep would not pass.
# ===========================================================================
run_fixture_selfasserts() {
  local t g m sp out

  t="$FIXTURES/tight/sample-test.sh"
  if [ -f "$t" ]; then
    out="$(lint_file "$t")"
    if printf '%s' "$out" | grep -F 'ceiling 20 below floor' >/dev/null 2>&1; then
      pass
    else
      note_fail "tight ceiling 20 flagged: FAILED — tight fixture (ceiling 20 < floor) was NOT flagged (floor lowered?) (got: '$out')"
    fi
  else
    note_fail "tight: fixture missing at $t"
  fi

  g="$FIXTURES/generous/sample-test.sh"
  if [ -f "$g" ]; then
    out="$(lint_file "$g")"
    if [ -z "$out" ]; then
      pass
    else
      note_fail "generous: ceiling 30 (>= floor) should NOT be flagged (got: '$out')"
    fi
  else
    note_fail "generous: fixture missing at $g"
  fi

  m="$FIXTURES/marked/sample-test.sh"
  if [ -f "$m" ]; then
    out="$(lint_file "$m")"
    if [ -z "$out" ]; then
      pass
    else
      note_fail "marked: tight ceiling with '# generous' marker should NOT be flagged (got: '$out')"
    fi
  else
    note_fail "marked: fixture missing at $m"
  fi

  sp="$FIXTURES/spaced/sample-test.sh"
  if [ -f "$sp" ]; then
    out="$(lint_file "$sp")"
    if [ -z "$out" ]; then
      pass
    else
      note_fail "spaced: quoted <pat> with embedded space, ceiling 30, should NOT be flagged (got: '$out')"
    fi
  else
    note_fail "spaced: fixture missing at $sp"
  fi
}

# ===========================================================================
# Real-tree scan — every tests/*.sh ceiling must be >= floor. SKIPPED under
# WOW_RED_WITHOUT_SELFTEST (169 recursion guard): an inner re-run of THIS lint
# runs only the fixture asserts.
# ===========================================================================
scan_real_tree() {
  local script base out
  for script in "$PLUGIN_ROOT/tests"/*.sh; do
    [ -f "$script" ] || continue
    base="$(basename "$script")"
    case "$base" in
      run-all.sh|run-all-inner.sh) continue ;;
    esac
    grep -qE 'wait_for' "$script" || continue
    out="$(lint_file "$script")"
    if [ -n "$out" ]; then
      while IFS= read -r finding; do
        [ -n "$finding" ] && note_fail "$finding"
      done <<EOF
$out
EOF
    fi
  done
}

# ===========================================================================
main() {
  run_fixture_selfasserts
  if [ "${WOW_RED_WITHOUT_SELFTEST:-}" != "1" ]; then
    scan_real_tree
  fi

  echo "lint-timing-ceilings: $PASS passed, $FAIL failed"
  if [ "$FAIL" -ne 0 ]; then
    for c in "${FAILED[@]}"; do echo "  - $c"; done
    exit 1
  fi
  exit 0
}

main "$@"
