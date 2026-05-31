#!/usr/bin/env bash
# Story 170 — behavioral test for run-all-inner.sh's --repeat-timing[=N] mode
# (the false-FAIL twin of 169's false-PASS guard).
#
# This is a CONSECUTIVE-REPEAT calibration check, NOT a concurrent-load harness:
# the mode re-runs the timing-flagged suite subset N× (default 4, clamp 3-5) and
# FLAKE-fails iff a suite passes on some runs AND fails on others (passes>0 &&
# fails>0). It catches a flake that recurs within N consecutive runs (~87.5% for
# a 50% independent flake at N=4) — effective for FINDING-46's class but not a
# substitute for a true concurrent-load harness.
#
# Driven over an ISOLATED scratch tests/ dir (a copy of run-all-inner.sh + two
# planted fixtures), NEVER the real suite. The planted-flake fixture uses a
# 0-based FRESH counter and fails on ODD index (0->pass, 1->fail, 2->pass,
# 3->fail), so:
#   - a plain 1× run (index 0) DETERMINISTICALLY passes  -> inner exit 0
#   - --repeat-timing=4 yields 2 pass / 2 fail = a true FLAKE -> inner exit != 0
# SEPARATE/reset counter files for the 1× vs 4× assertions keep each
# independently deterministic.
#
# RED-WITHOUT: patch .red-without/repeat-timing-aggregation.patch -> FLAKE: flake-fixture

set -u

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INNER="$PLUGIN_ROOT/tests/run-all-inner.sh"

PASS=0
FAIL=0
FAILED=()
pass() { PASS=$((PASS + 1)); }
note_fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# --- scratch builder ---------------------------------------------------------
# Builds an isolated tests/ dir holding run-all-inner.sh + a planted fixture.
# $1 = counter-file path the flake fixture reads/increments (FRESH per scenario).
# $2 = fixture flavor: "flake" (fail-on-odd) or "stable" (always pass).
build_scratch() {
  local counter="$1" flavor="$2" scratch
  scratch="$(mktemp -d)"
  cp "$INNER" "$scratch/run-all-inner.sh"

  if [ "$flavor" = "flake" ]; then
    cat > "$scratch/flake-fixture.sh" <<FIXTURE
#!/usr/bin/env bash
# Planted flake: 0-based FRESH counter, fail-on-odd index.
# wait_for sleep poll  <- timing-flagged keywords so --repeat-timing selects it.
set -u
COUNTER="$counter"
idx=0
[ -f "\$COUNTER" ] && idx="\$(cat "\$COUNTER")"
printf '%s' "\$((idx + 1))" > "\$COUNTER"
if [ "\$((idx % 2))" -eq 1 ]; then
  echo "flake-fixture: run index \$idx -> FAIL"
  exit 1
fi
echo "flake-fixture: run index \$idx -> pass"
exit 0
FIXTURE
  else
    cat > "$scratch/stable-fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Stable fixture: always passes. Carries timing keywords (wait_for sleep poll)
# so --repeat-timing selects it — and proves an always-pass suite is NOT a FLAKE.
set -u
echo "stable-fixture: pass"
exit 0
FIXTURE
  fi
  echo "$scratch"
}

# --- scenario 1: plain 1× run over the flake fixture -> index 0 -> exit 0 -----
c1="$(mktemp)"
rm -f "$c1"
s1="$(build_scratch "$c1" flake)"
out1="$(bash "$s1/run-all-inner.sh" 2>&1)"; rc1=$?
rm -rf "$s1"; rm -f "$c1"
if [ "$rc1" -eq 0 ]; then
  pass
else
  note_fail "1×: plain run over flake fixture (index 0) should exit 0, got rc=$rc1
--- output ---
$out1"
fi

# --- scenario 2: --repeat-timing=4 over the flake fixture -> FLAKE, exit != 0 -
c2="$(mktemp)"
rm -f "$c2"
s2="$(build_scratch "$c2" flake)"
out2="$(bash "$s2/run-all-inner.sh" --repeat-timing=4 2>&1)"; rc2=$?
rm -rf "$s2"; rm -f "$c2"
if [ "$rc2" -ne 0 ]; then
  pass
else
  note_fail "4×: --repeat-timing=4 over flake fixture should exit != 0, got rc=$rc2
--- output ---
$out2"
fi
if printf '%s' "$out2" | grep -F 'FLAKE: flake-fixture' >/dev/null 2>&1; then
  pass
else
  note_fail "4×: output should contain 'FLAKE: flake-fixture'
--- output ---
$out2"
fi

# --- scenario 3: --repeat-timing=4 over a STABLE fixture -> NO FLAKE, exit 0 --
c3="$(mktemp)"
rm -f "$c3"
s3="$(build_scratch "$c3" stable)"
out3="$(bash "$s3/run-all-inner.sh" --repeat-timing=4 2>&1)"; rc3=$?
rm -rf "$s3"; rm -f "$c3"
if [ "$rc3" -eq 0 ] && ! printf '%s' "$out3" | grep -F 'FLAKE:' >/dev/null 2>&1; then
  pass
else
  note_fail "stable: --repeat-timing=4 over always-pass fixture should exit 0 with NO FLAKE, got rc=$rc3
--- output ---
$out3"
fi

# ---------------------------------------------------------------------------
echo "repeat-timing-mode: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  for c in "${FAILED[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
