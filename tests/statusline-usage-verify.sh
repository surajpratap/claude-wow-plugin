#!/usr/bin/env bash
# Story 185 — statusline-usage-verify.sh: one-shot, opt-in end-to-end check of
# the usage-autopause chain (wrapper installed + wired + persists + the user's
# statusline actually emits rate_limits). The chain fails SILENTLY when a
# statusline doesn't expose rate_limits, so M runs this at startup (opt-in only,
# non-fatal) to surface the inert configuration.
#
# Cases:
#   a-healthy           — orig emits rate_limits + installed/wired/persists → exit 0, healthy.
#   b-wrapper-missing   — generated wrapper absent → installed:false, non-zero.
#   c-no-rate-limits    — orig emits NO rate_limits → statusline_emits_rate_limits:false, non-zero.
#   d-persist-unwritable— state path unwritable → persist_ok:false, non-zero.
#   e-slow-orig-bounded — a sleep-30 orig is bounded by the probe timeout: verify
#                         returns in <<30s and classifies the probe null (skip),
#                         proving the timeout actually bounds BOTH the persist
#                         self-test and the probe (no A&&timeout||fallback re-run).
#                         Skipped when timeout(1) is absent (documented unbounded
#                         fallback).
#
# RED-WITHOUT: patch .red-without/185-verify-always-healthy.patch -> c-no-rate-limits

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$ROOT/scripts/wow-process/statusline-usage-persist.sh"
VERIFY="$ROOT/scripts/wow-process/statusline-usage-verify.sh"

if [ ! -f "$VERIFY" ]; then
  echo "statusline-usage-verify: SKIP — $VERIFY not found"
  exit 0
fi
if [ ! -f "$WRAPPER" ]; then
  echo "statusline-usage-verify: SKIP — $WRAPPER (install helper) not found"
  exit 0
fi

GEN_BASENAME="wow-usage-statusline.sh"

# Build a temp CLAUDE_CONFIG_DIR whose statusline is the given orig command,
# then run statusline-usage-persist.sh --install so the generated wrapper +
# .statusLine.wowOriginalCommand are wired exactly as in production.
#   $1 = orig command string (the captured statusline)
# Prints the config dir path.
mk_installed_cfg() {
  local orig="$1" cfg
  cfg=$(mktemp -d)
  printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$orig" > "$cfg/settings.json"
  CLAUDE_CONFIG_DIR="$cfg" bash "$WRAPPER" --install >/dev/null 2>&1
  printf '%s' "$cfg"
}

CFGS=()

# ============================================================================
# (a) healthy — orig emits rate_limits; chain fully wired + persists
# ============================================================================
A_ORIG="$(mktemp -d)/orig.sh"
cat > "$A_ORIG" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":5}}}'
EOF
chmod +x "$A_ORIG"
CFG_A=$(mk_installed_cfg "bash $A_ORIG"); CFGS+=("$CFG_A")
JSON_A=$(CLAUDE_CONFIG_DIR="$CFG_A" bash "$VERIFY"); RC_A=$?
assert_eq "a-healthy-exit-0" "0" "$RC_A"
assert_eq "a-healthy-true" "true" "$(printf '%s' "$JSON_A" | jq -r '.healthy')"
assert_eq "a-installed" "true" "$(printf '%s' "$JSON_A" | jq -r '.checks.installed')"
assert_eq "a-wired" "true" "$(printf '%s' "$JSON_A" | jq -r '.checks.wired')"
assert_eq "a-persist_ok" "true" "$(printf '%s' "$JSON_A" | jq -r '.checks.persist_ok')"
assert_eq "a-sl-emits" "true" "$(printf '%s' "$JSON_A" | jq -r '.checks.statusline_emits_rate_limits')"

# ============================================================================
# (b) wrapper missing — generated script removed → installed:false
# ============================================================================
CFG_B=$(mk_installed_cfg "bash $A_ORIG"); CFGS+=("$CFG_B")
rm -f "$CFG_B/$GEN_BASENAME"
JSON_B=$(CLAUDE_CONFIG_DIR="$CFG_B" bash "$VERIFY"); RC_B=$?
assert_eq "b-wrapper-missing-nonzero" "nonzero" "$([ "$RC_B" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "b-installed-false" "false" "$(printf '%s' "$JSON_B" | jq -r '.checks.installed')"

# ============================================================================
# (c) no rate_limits — orig emits plain text → statusline_emits_rate_limits:false
# ============================================================================
C_ORIG="$(mktemp -d)/orig.sh"
cat > "$C_ORIG" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' 'just a plain status line'
EOF
chmod +x "$C_ORIG"
CFG_C=$(mk_installed_cfg "bash $C_ORIG"); CFGS+=("$CFG_C")
JSON_C=$(CLAUDE_CONFIG_DIR="$CFG_C" bash "$VERIFY"); RC_C=$?
assert_eq "c-no-rate-limits-nonzero" "nonzero" "$([ "$RC_C" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "c-sl-emits-false" "false" "$(printf '%s' "$JSON_C" | jq -r '.checks.statusline_emits_rate_limits')"
# installed/wired/persist still hold — only the emit check is the failure.
assert_eq "c-installed-true" "true" "$(printf '%s' "$JSON_C" | jq -r '.checks.installed')"
assert_eq "c-persist_ok-true" "true" "$(printf '%s' "$JSON_C" | jq -r '.checks.persist_ok')"

# ============================================================================
# (d) persist unwritable — probe state path's parent is a FILE, so the wrapper
#     cannot mkdir/write it → persist_ok:false (portable, root-immune: no chmod)
# ============================================================================
CFG_D=$(mk_installed_cfg "bash $A_ORIG"); CFGS+=("$CFG_D")
printf 'x' > "$CFG_D/blocker"          # a regular file where a dir would need to be
PROBE_D="$CFG_D/blocker/state.json"     # mkdir -p "$CFG_D/blocker" fails: it is a file
JSON_D=$(CLAUDE_CONFIG_DIR="$CFG_D" WOW_VERIFY_STATE_PROBE="$PROBE_D" bash "$VERIFY"); RC_D=$?
assert_eq "d-persist-unwritable-nonzero" "nonzero" "$([ "$RC_D" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "d-persist_ok-false" "false" "$(printf '%s' "$JSON_D" | jq -r '.checks.persist_ok')"

# ============================================================================
# (e) slow orig bounded — a sleep-30 statusline is bounded by the probe timeout.
#     Proves the timeout genuinely bounds the run (regression guard against the
#     A&&timeout||fallback idiom that re-runs unbounded on a 124 kill).
# ============================================================================
if command -v timeout >/dev/null 2>&1; then
  E_ORIG="$(mktemp -d)/orig.sh"
  cat > "$E_ORIG" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 30
printf '%s' '{"rate_limits":{}}'
EOF
  chmod +x "$E_ORIG"
  CFG_E=$(mk_installed_cfg "bash $E_ORIG"); CFGS+=("$CFG_E")
  T0=$(date +%s)
  JSON_E=$(CLAUDE_CONFIG_DIR="$CFG_E" WOW_VERIFY_TIMEOUT_S=2 bash "$VERIFY"); RC_E=$?
  T1=$(date +%s); ELAPSED=$((T1 - T0))
  assert_eq "e-bounded-well-under-30s" "yes" "$([ "$ELAPSED" -lt 20 ] && echo yes || echo no)"
  assert_eq "e-slow-orig-null-skip" "null" "$(printf '%s' "$JSON_E" | jq -r '.checks.statusline_emits_rate_limits')"
  # null (un-probable) does not fail health; the rest of the chain is sound.
  assert_eq "e-healthy-true" "true" "$(printf '%s' "$JSON_E" | jq -r '.healthy')"
else
  echo "statusline-usage-verify: (e-slow-orig-bounded) SKIP — timeout(1) absent; unbounded fallback is documented"
fi

for c in "${CFGS[@]}"; do rm -rf "$c"; done

echo "statusline-usage-verify: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
