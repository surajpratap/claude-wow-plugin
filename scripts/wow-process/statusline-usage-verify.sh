#!/usr/bin/env bash
# statusline-usage-verify.sh — Story 185. One-shot, end-to-end check of the
# usage-autopause chain (wrapper installed + wired + persists + the user's
# statusline actually emits rate_limits). The chain fails SILENTLY when a
# statusline does not expose rate_limits, so M runs this at startup (opt-in
# only) NON-FATALLY and surfaces the inert configuration.
#
# Prints to stdout:
#   {healthy, checks:{installed,wired,persist_ok,statusline_emits_rate_limits}, reason}
# Exit 0 = healthy; non-zero = inert/misconfigured. Health =
#   installed && wired && persist_ok && (statusline_emits_rate_limits != false)
# i.e. a null (un-probable) emit-check does NOT fail health.
#
# Both the persist self-test (check 3) and the emit probe (check 4) run the
# user's OWN statusline command (the generated wrapper delegates to it). A
# slow/hanging statusline must NOT hang M startup, so each is bounded by an
# EXPLICIT timeout branch — never `A && timeout || fallback`, which re-runs
# unbounded when timeout kills the command (exit 124). When timeout(1) is
# absent the run is unbounded by necessity (documented fallback).
#
# Test seams (set only by the test harness):
#   WOW_VERIFY_TIMEOUT_S   probe/persist timeout in seconds (default 5).
#   WOW_VERIFY_STATE_PROBE state path for the persist self-test (default mktemp).
set -u

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GEN="${CFG}/wow-usage-statusline.sh"
SETTINGS="${CFG}/settings.json"
TMO="${WOW_VERIFY_TIMEOUT_S:-5}"
FIXTURE='{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"used_percentage":11,"resets_at":"2030-01-02T00:00:00Z"}}}'

command -v jq >/dev/null 2>&1 || { printf '{"healthy":false,"checks":{},"reason":"jq not found"}\n'; exit 2; }

installed=false; wired=false; persist_ok=false; sl_json=null; reason=""

emit() {  # $1 healthy(bool literal) ; reads installed/wired/persist_ok/sl_json/reason
  jq -nc --argjson healthy "$1" --arg reason "$reason" \
    --argjson installed "$installed" --argjson wired "$wired" \
    --argjson persist_ok "$persist_ok" --argjson sl "$sl_json" \
    '{healthy:$healthy, checks:{installed:$installed, wired:$wired, persist_ok:$persist_ok, statusline_emits_rate_limits:$sl}, reason:$reason}'
}

# 1. installed — the generated wrapper exists and is executable.
if [ -x "$GEN" ]; then
  installed=true
else
  reason="wrapper not installed/executable at $GEN"
fi

# 2. wired — settings .statusLine.command points at the generated wrapper.
if [ "$installed" = true ] && [ -f "$SETTINGS" ]; then
  case "$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)" in
    *wow-usage-statusline.sh*) wired=true ;;
    *) reason="${reason:+$reason; }settings .statusLine.command is not wired to the wrapper" ;;
  esac
fi

# 3. persist_ok — feed the wrapper a rate_limits fixture + an isolated state
#    path; assert it persisted .five_hour.used_percentage. The wrapper persists
#    BEFORE delegating to the (possibly slow) original, so a timeout-kill still
#    leaves the state written — but bound it so a hanging original cannot hang us.
if [ "$installed" = true ]; then
  probe="${WOW_VERIFY_STATE_PROBE:-}"
  tmp_probe=""
  if [ -z "$probe" ]; then
    probe=$(mktemp 2>/dev/null) || probe=""
    tmp_probe="$probe"
  fi
  if [ -n "$probe" ]; then
    if command -v timeout >/dev/null 2>&1; then
      printf '%s' "$FIXTURE" | WOW_USAGE_STATE_FILE="$probe" timeout "$TMO" bash "$GEN" >/dev/null 2>&1 || true
    else
      printf '%s' "$FIXTURE" | WOW_USAGE_STATE_FILE="$probe" bash "$GEN" >/dev/null 2>&1 || true
    fi
    if [ "$(jq -r '.five_hour.used_percentage // empty' "$probe" 2>/dev/null)" = "42" ]; then
      persist_ok=true
    else
      reason="${reason:+$reason; }wrapper self-test did not persist rate_limits to the state file"
    fi
  else
    reason="${reason:+$reason; }could not create a probe temp file for the persist self-test"
  fi
  if [ -n "$tmp_probe" ]; then rm -f "$tmp_probe" 2>/dev/null || true; fi
fi

# 4. statusline_emits_rate_limits (best-effort) — run the user's recorded
#    original statusline against the fixture and inspect its OUTPUT (not exit
#    code). Contains rate_limits -> true; non-empty without -> false;
#    empty/killed/un-probable -> null (skip; never fails health).
if [ "$installed" = true ] && [ -f "$SETTINGS" ]; then
  orig=$(jq -r '.statusLine.wowOriginalCommand // empty' "$SETTINGS" 2>/dev/null)
  if [ -n "$orig" ]; then
    if command -v timeout >/dev/null 2>&1; then
      out=$(printf '%s' "$FIXTURE" | timeout "$TMO" sh -c "$orig" 2>/dev/null) || true
    else
      out=$(printf '%s' "$FIXTURE" | sh -c "$orig" 2>/dev/null) || true
    fi
    case "$out" in
      *rate_limits*) sl_json=true ;;
      "") : ;;
      *) sl_json=false; reason="${reason:+$reason; }your statusline does not emit rate_limits — usage auto-pause will never fire" ;;
    esac
  fi
fi

if [ "$installed" = true ] && [ "$wired" = true ] && [ "$persist_ok" = true ] && [ "$sl_json" != false ]; then
  emit true
  exit 0
fi
emit false
exit 1
