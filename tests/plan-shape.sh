#!/usr/bin/env bash
# Story 139 (backlog 160) — plan-shape-check.sh lints a plan file for the
# required `## AC count` section. Mechanizes the recurring NIT (PP flagged it
# on stories 117/120/124). The script lints SPECIFIC files passed to it (the
# plan under review) — NOT a blanket scan of implementations/plans/ (57/135
# non-draft plans predate the convention). Draft plans are exempt.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/plan-shape-check.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "plan-shape: FAIL — $SCRIPT not found" >&2
  exit 1
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# --- fixture builders ---------------------------------------------------------
mk_plan() {
  # mk_plan <name> <status> <with-ac-count: yes|no|typo>
  local name="$1" status="$2" ac="$3" f="$DIR/$1"
  {
    printf '<!-- status: %s -->\n\n# Plan %s\n\nStory: implementations/stories/%s.md\n\n' "$status" "$name" "$name"
    case "$ac" in
      yes)  printf '## AC count\nStory AC items: 3. All addressed below.\n\n' ;;
      typo) printf '## AC counted\nNot the real section heading.\n\n' ;;
      no)   : ;;
    esac
    printf '## Context\nbody.\n'
  } > "$f"
  echo "$f"
}

mk_plan_crlf() {
  # mk_plan_crlf <name> <status> — drafting plan with CRLF line endings, no AC count
  local name="$1" status="$2" f="$DIR/$1"
  printf '<!-- status: %s -->\r\n\r\n# Plan %s\r\n\r\n## Context\r\nbody.\r\n' "$status" "$name" > "$f"
  echo "$f"
}

# --- (a) non-draft + has AC count → pass (exit 0) -----------------------------
A=$(mk_plan "a-done.md" "done" yes)
if bash "$SCRIPT" "$A" >/dev/null 2>&1; then ok; else bad "a-compliant-done-should-pass"; fi

# --- (b) non-draft + missing → fail (exit 1) AND names the file ---------------
B=$(mk_plan "b-inreview.md" "in-review" no)
OUT_B=$(bash "$SCRIPT" "$B" 2>&1); RC_B=$?
if [ "$RC_B" -ne 0 ]; then ok; else bad "b-missing-should-fail (rc=$RC_B)"; fi
case "$OUT_B" in *"b-inreview.md"*) ok ;; *) bad "b-output-names-offender (got: $OUT_B)" ;; esac

# --- (c) draft + missing → exempt → pass (exit 0) -----------------------------
C=$(mk_plan "c-draft.md" "drafting" no)
if bash "$SCRIPT" "$C" >/dev/null 2>&1; then ok; else bad "c-draft-exempt-should-pass"; fi

# --- (d) two files: compliant + non-draft-missing → fail, names only offender -
D1=$(mk_plan "d1-ok.md" "approved" yes)
D2=$(mk_plan "d2-bad.md" "approved" no)
OUT_D=$(bash "$SCRIPT" "$D1" "$D2" 2>&1); RC_D=$?
if [ "$RC_D" -ne 0 ]; then ok; else bad "d-one-offender-should-fail (rc=$RC_D)"; fi
case "$OUT_D" in *"d2-bad.md"*) ok ;; *) bad "d-names-d2 (got: $OUT_D)" ;; esac
case "$OUT_D" in *"d1-ok.md"*) bad "d-must-not-name-compliant-d1 (got: $OUT_D)" ;; *) ok ;; esac

# --- (e) compliant trivial-tweak-format plan → pass ---------------------------
# (trivial-tweak template also carries `## AC count`; convention is uniform)
E=$(mk_plan "e-trivial.md" "done" yes)
if bash "$SCRIPT" "$E" >/dev/null 2>&1; then ok; else bad "e-trivial-tweak-compliant-should-pass"; fi

# --- (f) TWO offenders → fail, names BOTH (collect-all, not abort-on-first) ----
F1=$(mk_plan "f1-bad.md" "in-review" no)
F2=$(mk_plan "f2-bad.md" "implementing" no)
OUT_F=$(bash "$SCRIPT" "$F1" "$F2" 2>&1); RC_F=$?
if [ "$RC_F" -ne 0 ]; then ok; else bad "f-two-offenders-should-fail (rc=$RC_F)"; fi
case "$OUT_F" in *"f1-bad.md"*) ok ;; *) bad "f-names-f1 (got: $OUT_F)" ;; esac
case "$OUT_F" in *"f2-bad.md"*) ok ;; *) bad "f-names-f2-collect-all (got: $OUT_F)" ;; esac

# --- (g) `## AC counted` (end-anchor guard) → treated as MISSING → fail --------
G=$(mk_plan "g-typo.md" "done" typo)
if bash "$SCRIPT" "$G" >/dev/null 2>&1; then bad "g-AC-counted-must-not-false-pass"; else ok; fi

# --- (h) CRLF drafting marker → exempt → pass (CR stripped on line-1 read) -----
H=$(mk_plan_crlf "h-crlf-draft.md" "drafting")
if bash "$SCRIPT" "$H" >/dev/null 2>&1; then ok; else bad "h-crlf-draft-exempt-should-pass"; fi

echo "plan-shape: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
