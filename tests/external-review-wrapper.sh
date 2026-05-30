#!/usr/bin/env bash
# Story 112 — external-review.sh wrapper bakes in `< /dev/null` and supports
# env-var-configurable reviewer command + flags.

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
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1))
       FAILED_CASES+=("$name (haystack does not contain '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$ROOT/scripts/external-review.sh"

# ---- Case (a): wrapper exists + executable ----
if [ -f "$WRAPPER" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("a-wrapper-exists"); fi
if [ -x "$WRAPPER" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_CASES+=("a-wrapper-executable"); fi

# ---- Case (b): load-bearing `< /dev/null` ----
WRAPPER_BODY=$(cat "$WRAPPER")
assert_contains "b-stdin-redirect-baked-in" "< /dev/null" "$WRAPPER_BODY"

# ---- Case (c): env-var configurability ----
assert_contains "c-WOW_REVIEW_CMD-env-var"   "WOW_REVIEW_CMD"   "$WRAPPER_BODY"
assert_contains "c-WOW_REVIEW_FLAGS-env-var" "WOW_REVIEW_FLAGS" "$WRAPPER_BODY"
assert_contains "c-default-codex"            ':-codex'          "$WRAPPER_BODY"

# ---- Case (d): missing -o → exit 2 + usage ----
OUT_D=$(bash "$WRAPPER" 2>&1)
RC_D=$?
assert_eq       "d-missing-args-rc2" "2" "$RC_D"
assert_contains "d-usage-on-stderr" "usage:" "$OUT_D"
# Missing prompt (only -o supplied) → exit 2 too.
OUT_D2=$(bash "$WRAPPER" -o /tmp/x 2>&1)
RC_D2=$?
assert_eq "d-missing-prompt-rc2" "2" "$RC_D2"

# ---- Case (e): end-to-end stub override ----
STUB_DIR=$(mktemp -d)
STUB="$STUB_DIR/codex-stub.sh"
RECORD="$STUB_DIR/recorded.txt"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
# Stub reviewer: records argv + whether stdin was already EOF, then exits.
{
  echo "ARGS: \$*"
  # Confirm stdin is immediately EOF via cat returning empty.
  if [ -z "\$(cat 2>/dev/null)" ]; then
    echo "STDIN: eof"
  else
    echo "STDIN: data-available"
  fi
} > "$RECORD" 2>&1
exit 0
EOF
chmod +x "$STUB"

WOW_REVIEW_CMD="$STUB" WOW_REVIEW_FLAGS="--stub-flag-a --stub-flag-b" \
  bash "$WRAPPER" -o /tmp/extrev-out.txt "test prompt body" >/dev/null 2>&1
RC_E=$?
# Stub returns 0; exec preserves the exit code.
assert_eq "e-stub-rc0" "0" "$RC_E"
REC=$(cat "$RECORD" 2>/dev/null)
assert_contains "e-stub-saw-exec-arg"      "exec"                  "$REC"
assert_contains "e-stub-saw-stub-flag-a"   "--stub-flag-a"          "$REC"
assert_contains "e-stub-saw-stub-flag-b"   "--stub-flag-b"          "$REC"
assert_contains "e-stub-saw-output-flag"   "-o /tmp/extrev-out.txt" "$REC"
assert_contains "e-stub-saw-prompt"        "test prompt body"       "$REC"
assert_contains "e-stub-stdin-eof"         "STDIN: eof"             "$REC"
rm -rf "$STUB_DIR"

# RED-WITHOUT: patch .red-without/external-review-prompt-file.patch -> f-metachar-verbatim
# ---- Case (f): --prompt-file delivers metachars VERBATIM (no shell substitution) ----
# A backtick / $(...) in a plan or review prompt must reach the reviewer as
# literal bytes — the footgun (168-r2) was PP's own shell substituting an inline
# "<prompt>" before the wrapper ran. The file route makes metachars inert.
STUB_DIR2=$(mktemp -d); STUB2="$STUB_DIR2/codex-stub.sh"; RECORD2="$STUB_DIR2/rec.txt"
# stub records the reviewer's LAST argv arg (the prompt) byte-for-byte.
cat > "$STUB2" <<EOF
#!/usr/bin/env bash
printf 'PROMPT:[%s]\n' "\${@: -1}" > "$RECORD2"
exit 0
EOF
chmod +x "$STUB2"
# single-quoted: the backtick/\$()/redirect are INERT in this test's own shell.
BODY='ARMING-PREFACE-SENTINEL then a literal `whoami` and $(id) and a < redirect'
PF="$STUB_DIR2/prompt.txt"; printf '%s' "$BODY" > "$PF"
WOW_REVIEW_CMD="$STUB2" WOW_REVIEW_FLAGS="--stub" \
  bash "$WRAPPER" -o /tmp/extrev-f.txt --prompt-file "$PF" >/dev/null 2>&1
RC_F=$?
assert_eq "f-prompt-file-rc0" "0" "$RC_F"
REC_F=$(cat "$RECORD2" 2>/dev/null)
# byte-for-byte: the FULL literal body (incl. the un-substituted `whoami`/$(id))
# is what the reviewer got. Substitution would have left a username/uid instead.
assert_eq "f-metachar-verbatim" "PROMPT:[$BODY]" "$REC_F"
assert_contains "f-preface-survives" "ARMING-PREFACE-SENTINEL" "$REC_F"
rm -rf "$STUB_DIR2"

echo "external-review-wrapper: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
