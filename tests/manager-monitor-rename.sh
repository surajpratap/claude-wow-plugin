#!/usr/bin/env bash
# Story 186 — the idle-monitor -> manager-monitor rename is wired through every
# canonical contract surface: the daemon + wrapper files, the role-process-map
# purpose (the canonical arm list), monitor-spec's case block, the monitor-pipe
# doc enumeration, phase_bootstrap's hardcoded arming, and the wrapper pidfile
# (what post-compact-restore keys on). A config-shape test (the arming itself
# needs a live session role-marker, out of scope here).
#
# RED-WITHOUT: patch .red-without/186-purpose-revert.patch -> a-map-has-manager-monitor

set -u

PASS=0
FAIL=0
FAILED_CASES=()
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WP="$ROOT/scripts/wow-process"
MAP="$WP/role-process-map.json"

# (a) role-process-map: manager arms manager-monitor, NOT idle-monitor.
assert_eq "a-map-has-manager-monitor" "true" \
  "$(jq -r '.manager | (index("manager-monitor") != null)' "$MAP" 2>/dev/null)"
assert_eq "a-map-no-idle-monitor" "false" \
  "$(jq -r '.manager | (index("idle-monitor") != null)' "$MAP" 2>/dev/null)"

# (b) daemon + wrapper files renamed; old names gone.
assert_eq "b-py-renamed"  "yes" "$([ -f "$WP/manager-monitor.py" ] && echo yes || echo no)"
assert_eq "b-sh-renamed"  "yes" "$([ -f "$WP/manager-monitor.sh" ] && echo yes || echo no)"
assert_eq "b-old-py-gone" "yes" "$([ ! -e "$WP/idle-monitor.py" ] && echo yes || echo no)"
assert_eq "b-old-sh-gone" "yes" "$([ ! -e "$WP/idle-monitor.sh" ] && echo yes || echo no)"

# (c) monitor-spec case block + monitor-pipe doc enumeration name manager-monitor.
assert_eq "c-monitor-spec-case" "yes" \
  "$(grep -qE '^[[:space:]]*manager-monitor\)' "$WP/monitor-spec.sh" && echo yes || echo no)"
assert_eq "c-monitor-pipe-sh-doc" "yes" \
  "$(grep -q 'manager-monitor' "$WP/monitor-pipe.sh" && echo yes || echo no)"

# (d) phase_bootstrap arms "manager-monitor" (the load-bearing hardcoded arming).
assert_eq "d-phase-bootstrap-arms" "yes" \
  "$(grep -q 'build_arm_monitor_command "manager-monitor"' "$ROOT/scripts/startup/phase_bootstrap.sh" && echo yes || echo no)"
assert_eq "d-phase-bootstrap-expect" "yes" \
  "$(grep -q '"manager-monitor"' "$ROOT/scripts/startup/phase_bootstrap.sh" && echo yes || echo no)"

# (e) wrapper pidfile uses the new name (post-compact-restore keys on it).
assert_eq "e-pidfile-renamed" "yes" \
  "$(grep -q 'manager-monitor-\${WOW_ROLE}.pid' "$WP/manager-monitor.sh" && echo yes || echo no)"

# (f) events-dir naming derives from the purpose — the wrapper-arm purpose is
#     manager-monitor, so the events dir is .monitor-events/manager-monitor/.
#     (phase_bootstrap pipes `--purpose manager-monitor`; legacy doctrine too.)
assert_eq "f-events-dir-purpose" "yes" \
  "$(grep -rq 'monitor-events/manager-monitor' "$ROOT/commands" 2>/dev/null && echo yes || echo no)"

echo "manager-monitor-rename: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
