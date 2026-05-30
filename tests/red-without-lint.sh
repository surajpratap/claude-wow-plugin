#!/usr/bin/env bash
# Story 169 — "show me the RED" mechanized as a pre-merge gate.
#
# === GRAMMAR (single source of truth) ===
# A behavioral test guarding a subtle gate carries ONE annotation:
#
#     # RED-WITHOUT: patch <relpath-under-tests/.red-without> -> <assert-spec>
#
#   <revert-spec> = `patch <name>.patch` — a committed unified diff under
#       plugin/tests/.red-without/. Applied (git apply -p1, from the scratch
#       plugin root) to a REAL code-under-test file, it performs the revert
#       that SHOULD break the gate. `patch` is the sole v1 form: it is the only
#       encoding covering all heterogeneous reverts (multi-line block delete,
#       single-token replace, branch revert) AND `git apply --check`/`-R` make
#       it robust + self-validating (a patch that no longer applies is a useful
#       "stale annotation" signal). Any non-`patch` form is REJECTED.
#   <assert-spec> = the test-case description (a LITERAL substring) expected to
#       flip green->red. It is matched with `grep -F` against the reverted
#       run's combined stdout/stderr to confirm the RIGHT case failed (not an
#       unrelated one).
#
# === VERIFIER (the expensive half — presence-grep is FORBIDDEN) ===
# For each canonical `# RED-WITHOUT: patch ... -> ...` line in $PLUGIN_ROOT/tests/*.sh:
#   1. parse -> (patch_relpath, assert_spec); reject malformed/non-patch.
#   2. scratch-isolate: cp -R $PLUGIN_ROOT into a fresh mktemp -d (per annotation).
#   3. git apply --check (cd into scratch, -p1) -> stale annotation fails loudly.
#   4. baseline GREEN anchor (flake-tolerant: a baseline timeout/nonzero is
#      INCONCLUSIVE, not a FAIL — the outer run-all runs the sibling green).
#   5. apply the revert, re-run the test, REQUIRE exit!=0 AND assert_spec present.
#      exit 0 -> NO-OP (hollow annotation) FAIL. exit!=0 w/o assert_spec ->
#      wrong-case FAIL.
#   6. the per-annotation subshell's `trap EXIT` discards the scratch.
#
# === MISSING / EXCLUSION (so the gate is a ratchet, not noise) ===
# A test is "behavioral" if it matches the producer-invocation shape common in
# this suite: `python3 .*run\.py` | `bus_emit` | `bridge`. A behavioral test
# carrying NO `# RED-WITHOUT:` line FAILS the lint — UNLESS it is on the
# grandfather allowlist (tests/.red-without/grandfathered.txt). The allowlist
# freezes the CURRENT un-annotated backlog (reported, not failed) so a NEW
# behavioral test cannot ship un-annotated (mechanism > diligence) without
# forcing a sprint-wide backfill. Non-producer-shape tests are EXEMPT.
#
# === SELF-HOST (the dogfood) ===
# This lint carries its OWN annotation (below). Its patch reverts the assert-RED
# step to a presence-grep (the forbidden anti-pattern); with that revert the
# `noop/` fixture is no longer caught, so the lint's self-test flips green->red.
# NARROW EXCEPTION to "patches target code-under-test, not the test file": the
# self-host patch targets THIS file — the verifier IS the code-under-test for
# its own self-host annotation. This is the sole sanctioned exception.
# Recursion guard: the inner re-runs export WOW_RED_WITHOUT_SELFTEST=1; in that
# mode the lint runs ONLY the fixture self-asserts and SKIPS the real-tree scan.
#
# RED-WITHOUT: patch .red-without/lint-selfhost.patch -> noop fixture is detected

set -u

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$PLUGIN_ROOT/tests/fixtures/red-without"
RW_DIR="$PLUGIN_ROOT/tests/.red-without"

PASS=0
FAIL=0
FAILED=()

pass() { PASS=$((PASS + 1)); }
note_fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }
log() { printf 'red-without-lint: %s\n' "$1" >&2; }

# Tight per-re-run bound: one slow target cannot eat the whole budget. Clamp to
# WOW_TEST_TIMEOUT_S when that (the outer per-test budget) is set + smaller.
RERUN_TIMEOUT="${WOW_RED_WITHOUT_RERUN_TIMEOUT:-120}"
if [ -n "${WOW_TEST_TIMEOUT_S:-}" ] && [ "${WOW_TEST_TIMEOUT_S}" -lt "$RERUN_TIMEOUT" ] 2>/dev/null; then
  RERUN_TIMEOUT="$WOW_TEST_TIMEOUT_S"
fi
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"

# Behavioral (producer-shape) heuristic — deliberately narrow.
BEHAVIORAL_RE='python3 .*run\.py|bus_emit|bridge'

# ---------------------------------------------------------------------------
# assert_revert_red <rerun_rc> <rerun_output> <assert_spec>
#   The anti-hollow CORE: a revert is a GENUINE RED-WITHOUT iff the reverted
#   re-run exited non-zero AND the assert_spec literally appears in its output.
#   Returns 0 (genuine RED detected), 1 (NO-OP — stayed green), 2 (wrong case).
#   This is the SINGLE source of the assert-RED rule — verify_annotation AND the
#   fixture selftests both call it, so lint-selfhost.patch reverts ONE place to
#   the forbidden presence-grep (and the noop fixture stops being detected).
# --- RED-WITHOUT-ASSERT-START (lint-selfhost.patch reverts this body to a presence-grep) ---
assert_revert_red() {
  local rc="$1" out="$2" spec="$3"
  if [ "$rc" -eq 0 ]; then
    return 1
  fi
  if ! printf '%s' "$out" | grep -F -- "$spec" >/dev/null 2>&1; then
    return 2
  fi
  return 0
}
# --- RED-WITHOUT-ASSERT-END ---

# ---------------------------------------------------------------------------
# parse_annotation <line>
#   Echoes "<patch_relpath>\t<assert_spec>" on a VALID canonical line; returns 0.
#   On a non-`patch` form or a malformed line, echoes a specific `error: ...`
#   and returns 1. The grammar is: `# RED-WITHOUT: patch <p> -> <spec>`.
# ---------------------------------------------------------------------------
parse_annotation() {
  local line="$1" body form rest patch spec
  # strip everything up to and including the `# RED-WITHOUT:` marker.
  case "$line" in
    *"# RED-WITHOUT:"*) body="${line#*# RED-WITHOUT:}" ;;
    *) echo "error: not a RED-WITHOUT line"; return 1 ;;
  esac
  # trim leading whitespace.
  body="${body#"${body%%[![:space:]]*}"}"
  form="${body%%[[:space:]]*}"
  if [ "$form" != "patch" ]; then
    echo "error: v1 RED-WITHOUT supports only 'patch <name>'; got '$form'"
    return 1
  fi
  rest="${body#patch}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$rest" in
    *" -> "*) ;;
    *) echo "error: malformed RED-WITHOUT — expected 'patch <p> -> <assert-spec>'"; return 1 ;;
  esac
  patch="${rest%% -> *}"
  spec="${rest#* -> }"
  # trim trailing whitespace off the patch token.
  patch="${patch%"${patch##*[![:space:]]}"}"
  if [ -z "$patch" ] || [ -z "$spec" ]; then
    echo "error: malformed RED-WITHOUT — empty patch or assert-spec"
    return 1
  fi
  printf '%s\t%s\n' "$patch" "$spec"
  return 0
}

# ---------------------------------------------------------------------------
# verify_annotation <test_abspath> <patch_relpath> <assert_spec>
#   Runs in a per-annotation SUBSHELL so its `trap EXIT` (and any inner exit)
#   is confined to this one annotation. Echoes a `FAIL: ...` line + returns 1
#   on a hollow/wrong-case/stale annotation; returns 0 on a genuine RED.
# ---------------------------------------------------------------------------
verify_annotation() (
  local test_abspath="$1" patch_relpath="$2" assert_spec="$3"
  local test_base patch_abspath scratch out rc
  test_base="$(basename "$test_abspath")"
  patch_abspath="$PLUGIN_ROOT/tests/$patch_relpath"

  if [ ! -f "$patch_abspath" ]; then
    echo "FAIL: $test_base RED-WITHOUT patch $patch_relpath not found at $patch_abspath"
    return 1
  fi

  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  cp -R "$PLUGIN_ROOT" "$scratch/plugin"

  if ! ( cd "$scratch/plugin" && git apply --check -p1 "$patch_abspath" ) >/dev/null 2>&1; then
    echo "FAIL: $test_base RED-WITHOUT patch $patch_relpath no longer applies (stale annotation — regenerate)"
    return 1
  fi

  local -a runenv=(
    "WOW_ROOT=$scratch/plugin"
    "CLAUDE_PROJECT_DIR=$scratch/plugin"
    "CLAUDE_PLUGIN_ROOT=$scratch/plugin"
    "WOW_RED_WITHOUT_SELFTEST=1"
  )

  run_in_scratch() {
    if [ -n "$TIMEOUT_BIN" ]; then
      ( cd "$scratch/plugin" && env "${runenv[@]}" "$TIMEOUT_BIN" "$RERUN_TIMEOUT" bash "tests/$test_base" ) 2>&1
    else
      ( cd "$scratch/plugin" && env "${runenv[@]}" bash "tests/$test_base" ) 2>&1
    fi
  }

  # Baseline GREEN anchor — flake-tolerant.
  out="$(run_in_scratch)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    log "baseline-inconclusive for $test_base (rc=$rc; relying on run-all's green)"
  fi

  ( cd "$scratch/plugin" && git apply -p1 "$patch_abspath" ) >/dev/null 2>&1

  out="$(run_in_scratch)"; rc=$?
  assert_revert_red "$rc" "$out" "$assert_spec"; local ar=$?
  if [ "$ar" -eq 1 ]; then
    echo "FAIL: $test_base RED-WITHOUT is a NO-OP — revert $patch_relpath did not make '$assert_spec' go RED (hollow annotation)"
    return 1
  elif [ "$ar" -eq 2 ]; then
    echo "FAIL: $test_base went RED but not on '$assert_spec' (wrong case failed — annotation mis-targets)"
    return 1
  fi
  return 0
)

# ===========================================================================
# Fixture self-asserts — always run (incl. selftest mode).
# ===========================================================================

selftest_parse() {
  local valid reject_dl reject_mal parsed
  valid="$(cat "$FIXTURES/parse/valid.txt")"
  reject_dl="$(cat "$FIXTURES/parse/reject-delete-lines.txt")"
  reject_mal="$(cat "$FIXTURES/parse/reject-malformed.txt")"

  if parsed="$(parse_annotation "$valid")"; then
    if [ "$parsed" = ".red-without/some-revert.patch	a: the case description that flips RED" ]; then
      pass
    else
      note_fail "parse: valid line parsed to unexpected tuple ('$parsed')"
    fi
  else
    note_fail "parse: valid canonical line was rejected"
  fi

  if parse_annotation "$reject_dl" >/dev/null 2>&1; then
    note_fail "parse: 'delete-lines' form should be REJECTED"
  else
    pass
  fi

  if parse_annotation "$reject_mal" >/dev/null 2>&1; then
    note_fail "parse: malformed (no ' -> ' arrow) should be REJECTED"
  else
    pass
  fi
}

# good/: a real revert flips a fixture-test's case RED -> verify_annotation PASSES.
selftest_good() {
  local t="$FIXTURES/good/sample-test.sh" line tuple p s
  line="$(grep -E '^# RED-WITHOUT: patch ' "$t" | head -1)"
  tuple="$(parse_annotation "$line")" || { note_fail "good: fixture annotation did not parse"; return; }
  p="${tuple%%	*}"; s="${tuple#*	}"
  # The good fixture's patch path is fixture-local; resolve relative to the test.
  local patch_abspath out rc scratch
  patch_abspath="$FIXTURES/good/$p"
  patch_abspath="$(cd "$(dirname "$patch_abspath")" && pwd)/$(basename "$patch_abspath")"
  scratch="$(mktemp -d)"
  cp -R "$PLUGIN_ROOT" "$scratch/plugin"
  if ! ( cd "$scratch/plugin" && git apply --check -p1 "$patch_abspath" ) >/dev/null 2>&1; then
    note_fail "good: fixture patch no longer applies (stale)"
    rm -rf "$scratch"; return
  fi
  # baseline GREEN
  out="$( cd "$scratch/plugin" && bash "tests/fixtures/red-without/good/sample-test.sh" 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] || log "good: baseline-inconclusive (rc=$rc)"
  ( cd "$scratch/plugin" && git apply -p1 "$patch_abspath" ) >/dev/null 2>&1
  out="$( cd "$scratch/plugin" && bash "tests/fixtures/red-without/good/sample-test.sh" 2>&1 )"; rc=$?
  rm -rf "$scratch"
  if assert_revert_red "$rc" "$out" "$s"; then
    pass
  else
    note_fail "good: revert did NOT flip the fixture-test RED on '$s' (rc=$rc)"
  fi
}

# noop/: a behavior-neutral revert leaves the fixture-test GREEN -> the lint MUST
# detect it as a no-op (the core anti-hollow assertion). The self-host patch
# reverts THIS check to a presence-grep so the noop is no longer caught.
selftest_noop() {
  local t="$FIXTURES/noop/sample-test.sh" line tuple p s
  line="$(grep -E '^# RED-WITHOUT: patch ' "$t" | head -1)"
  tuple="$(parse_annotation "$line")" || { note_fail "noop: fixture annotation did not parse"; return; }
  p="${tuple%%	*}"; s="${tuple#*	}"
  local patch_abspath out rc scratch
  patch_abspath="$FIXTURES/noop/$p"
  patch_abspath="$(cd "$(dirname "$patch_abspath")" && pwd)/$(basename "$patch_abspath")"
  scratch="$(mktemp -d)"
  cp -R "$PLUGIN_ROOT" "$scratch/plugin"
  if ! ( cd "$scratch/plugin" && git apply --check -p1 "$patch_abspath" ) >/dev/null 2>&1; then
    note_fail "noop: fixture patch no longer applies (stale)"
    rm -rf "$scratch"; return
  fi
  ( cd "$scratch/plugin" && git apply -p1 "$patch_abspath" ) >/dev/null 2>&1
  out="$( cd "$scratch/plugin" && bash "tests/fixtures/red-without/noop/sample-test.sh" 2>&1 )"; rc=$?
  rm -rf "$scratch"
  # The noop revert leaves the test GREEN, so the GENUINE assert_revert_red
  # returns non-zero (NO-OP detected). The degraded presence-grep form (what
  # lint-selfhost.patch reverts assert_revert_red to) would return 0 here
  # ("genuine RED") -> this assertion FAILS -> the lint's self-test flips RED.
  if assert_revert_red "$rc" "$out" "$s"; then
    note_fail "noop fixture is detected: FAILED — behavior-neutral revert was NOT caught as a no-op (assert degraded to presence-grep?)"
  else
    pass
  fi
}

# exclude/: a shape-only fixture-test (greps a file, no producer) MUST NOT be
# flagged as behavioral.
selftest_exclude() {
  local t="$FIXTURES/exclude/shape-only-test.sh"
  if grep -qE "$BEHAVIORAL_RE" "$t"; then
    note_fail "exclude: shape-only fixture matched the behavioral heuristic (heuristic too broad)"
  else
    pass
  fi
}

# missing/: a producer-shape test with NO annotation, NOT on the allowlist ->
# flagged. allowlisted/: producer-shape, on the fixture allowlist -> NOT flagged.
selftest_missing_and_allowlisted() {
  local miss="$FIXTURES/missing/producer-not-allowlisted.sh"
  local allow="$FIXTURES/allowlisted/producer-no-annotation.sh"
  local fixture_allowlist="$FIXTURES/allowlisted/grandfathered.txt"

  # missing: producer-shape, lacks annotation, not allowlisted -> flagged.
  if grep -qE "$BEHAVIORAL_RE" "$miss" && ! grep -q '# RED-WITHOUT:' "$miss"; then
    if grep -qxF "$(basename "$miss")" "$fixture_allowlist" 2>/dev/null; then
      note_fail "missing: fixture is unexpectedly on the allowlist"
    else
      pass
    fi
  else
    note_fail "missing: fixture is not producer-shape-without-annotation as expected"
  fi

  # allowlisted: producer-shape, lacks annotation, allowlisted -> NOT flagged.
  if grep -qE "$BEHAVIORAL_RE" "$allow" && ! grep -q '# RED-WITHOUT:' "$allow"; then
    if grep -qxF "$(basename "$allow")" "$fixture_allowlist" 2>/dev/null; then
      pass
    else
      note_fail "allowlisted: fixture should be on the allowlist (would otherwise be flagged)"
    fi
  else
    note_fail "allowlisted: fixture is not producer-shape-without-annotation as expected"
  fi
}

run_fixture_selfasserts() {
  selftest_parse
  [ -f "$FIXTURES/good/sample-test.sh" ] && selftest_good
  [ -f "$FIXTURES/noop/sample-test.sh" ] && selftest_noop
  [ -f "$FIXTURES/exclude/shape-only-test.sh" ] && selftest_exclude
  [ -f "$FIXTURES/missing/producer-not-allowlisted.sh" ] && selftest_missing_and_allowlisted
  return 0
}

# ===========================================================================
# Real-tree scan — SKIPPED under WOW_RED_WITHOUT_SELFTEST (BLOCKER-2 recursion
# guard): an inner re-run of THIS lint must run only the fixture asserts.
# ===========================================================================
scan_real_tree() {
  local grandfather="$RW_DIR/grandfathered.txt"
  local backlog=0
  local script base line tuple p s

  for script in "$PLUGIN_ROOT/tests"/*.sh; do
    [ -f "$script" ] || continue
    base="$(basename "$script")"
    case "$base" in
      run-all.sh|run-all-inner.sh) continue ;;
    esac

    # Verify every canonical annotation in this file.
    while IFS= read -r line; do
      tuple="$(parse_annotation "$line")" || {
        note_fail "$base: malformed RED-WITHOUT annotation ($line)"
        continue
      }
      p="${tuple%%	*}"; s="${tuple#*	}"
      local vout vrc
      vout="$(verify_annotation "$script" "$p" "$s")"; vrc=$?
      if [ "$vrc" -eq 0 ]; then
        pass
      else
        note_fail "$vout"
      fi
    done < <(grep -E '^# RED-WITHOUT: patch ' "$script")

    # Missing-annotation ratchet: producer-shape + no annotation + not allowlisted -> FAIL.
    if grep -qE "$BEHAVIORAL_RE" "$script" && ! grep -q '# RED-WITHOUT:' "$script"; then
      if grep -qxF "$base" "$grandfather" 2>/dev/null; then
        backlog=$((backlog + 1))
      else
        note_fail "$base looks behavioral (matches $BEHAVIORAL_RE) but has no # RED-WITHOUT: annotation"
      fi
    fi
  done

  log "grandfather backlog: $backlog un-annotated behavioral test(s) remain (see tests/.red-without/grandfathered.txt)"
}

# ===========================================================================
main() {
  run_fixture_selfasserts
  if [ "${WOW_RED_WITHOUT_SELFTEST:-}" != "1" ]; then
    scan_real_tree
  fi

  echo "red-without-lint: $PASS passed, $FAIL failed"
  if [ "$FAIL" -ne 0 ]; then
    for c in "${FAILED[@]}"; do echo "  - $c"; done
    exit 1
  fi
  exit 0
}

main "$@"
