#!/usr/bin/env bash
# Story 071 — wow-process wrapper PID-uniqueness + manifest coherence.
#
# Spec cases (1-7) plus manifest-coherence pairs. Uses a fixture script that
# mirrors the wrapper template with `exec sleep 30` as the target — keeps the
# PID-uniqueness mechanic under test without depending on any specific
# wrapper's runtime behavior (bus-tail polling loop, fswatch missing, etc).

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
WOW_PROCESS_DIR_TPL="implementations/.wow-process"
ROLE_MAP="$ROOT/scripts/wow-process/role-process-map.json"

mk_project() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude-plugin" "$d/implementations"
  echo '{"name":"x","version":"0.0.0"}' > "$d/.claude-plugin/plugin.json"
  echo "$d"
}

# Build a fixture wrapper script with the spec template + `exec sleep 30` as
# the target. Writes a script at $1 with PURPOSE/CONFLICT_POLICY from $2/$3.
mk_fixture() {
  local path="$1" purpose="$2" policy="$3"
  cat > "$path" << FIXTURE_EOF
#!/usr/bin/env bash
set -u
PURPOSE="$purpose"
CONFLICT_POLICY="$policy"
WOW_ROOT="\${WOW_ROOT:-\$(pwd)}"
WOW_ROLE="\${WOW_ROLE:-test-role}"
WOW_PROCESS_DIR="\${WOW_ROOT}/implementations/.wow-process"
PIDFILE="\${WOW_PROCESS_DIR}/\${PURPOSE}-\${WOW_ROLE}.pid"
CONF="\${WOW_PROCESS_DIR}/\${PURPOSE}.conf"
[ -f "\$CONF" ] && . "\$CONF"
echo "[fixture-conf-marker:\${WOW_PROCESS_TEST_MARKER:-DEFAULT}]"
if [ -f "\$PIDFILE" ]; then
  PRIOR_PID=\$(cat "\$PIDFILE" 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "\${PRIOR_PID:-}" ] && kill -0 "\$PRIOR_PID" 2>/dev/null; then
    case "\$CONFLICT_POLICY" in
      kill)
        kill -TERM "\$PRIOR_PID" 2>/dev/null || true
        sleep 2
        kill -0 "\$PRIOR_PID" 2>/dev/null && kill -KILL "\$PRIOR_PID" 2>/dev/null || true
        ;;
      raise)
        echo "[wow-process:\${PURPOSE}] conflict: PID \$PRIOR_PID alive; refusing to spawn" >&2
        exit 2
        ;;
    esac
  fi
fi
mkdir -p "\$WOW_PROCESS_DIR"
echo "\$\$" > "\$PIDFILE"
# NOTE: production wrappers \`exec\` here (template literal). The fixture
# keeps the shell + an explicit-exit trap so the trap fires under SIGTERM
# during test cleanup. Production wrappers rely on stale-PID detection
# on next arm for the signal-kill case per spec.
trap 'rm -f "\$PIDFILE"; exit 130' INT TERM
trap 'rm -f "\$PIDFILE"' EXIT
sleep 5
FIXTURE_EOF
  chmod +x "$path"
}

# -----------------------------------------------------------------------------
# Case 1: No prior PID file → spawn succeeds, PID file written.
# -----------------------------------------------------------------------------
P1=$(mk_project)
mk_fixture "$P1/wrapper.sh" "case1" "kill"
WOW_ROOT="$P1" WOW_ROLE="r1" bash "$P1/wrapper.sh" >/dev/null 2>&1 &
PID1=$!
sleep 1
PIDFILE1="$P1/$WOW_PROCESS_DIR_TPL/case1-r1.pid"
[ -f "$PIDFILE1" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-1-pidfile-written"); }
kill -TERM "$PID1" 2>/dev/null || true
wait "$PID1" 2>/dev/null || true
rm -rf "$P1"

# -----------------------------------------------------------------------------
# Case 2: Stale PID file (dead PID) → spawn succeeds, PID file overwritten.
# -----------------------------------------------------------------------------
P2=$(mk_project)
mk_fixture "$P2/wrapper.sh" "case2" "kill"
mkdir -p "$P2/$WOW_PROCESS_DIR_TPL"
echo "999999" > "$P2/$WOW_PROCESS_DIR_TPL/case2-r1.pid"
WOW_ROOT="$P2" WOW_ROLE="r1" bash "$P2/wrapper.sh" >/dev/null 2>&1 &
PID2=$!
sleep 1
NEW_PID2=$(cat "$P2/$WOW_PROCESS_DIR_TPL/case2-r1.pid" 2>/dev/null)
if [ -n "$NEW_PID2" ] && [ "$NEW_PID2" != "999999" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case-2-stale-pidfile-overwritten (still '999999' or empty: '$NEW_PID2')")
fi
kill -TERM "$PID2" 2>/dev/null || true
wait "$PID2" 2>/dev/null || true
rm -rf "$P2"

# -----------------------------------------------------------------------------
# Case 3: Live PID file, policy=kill → prior process dies; new spawn succeeds.
# -----------------------------------------------------------------------------
P3=$(mk_project)
mk_fixture "$P3/wrapper.sh" "case3" "kill"
WOW_ROOT="$P3" WOW_ROLE="r1" bash "$P3/wrapper.sh" >/dev/null 2>&1 &
FIRST_PID=$!
sleep 1
WOW_ROOT="$P3" WOW_ROLE="r1" bash "$P3/wrapper.sh" >/dev/null 2>&1 &
SECOND_PID=$!
sleep 3
if kill -0 "$FIRST_PID" 2>/dev/null; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case-3-kill-policy-prior-dead (first PID $FIRST_PID still alive)")
else
  PASS=$((PASS+1))
fi
kill -TERM "$SECOND_PID" 2>/dev/null || true
wait "$FIRST_PID" 2>/dev/null || true
wait "$SECOND_PID" 2>/dev/null || true
rm -rf "$P3"

# -----------------------------------------------------------------------------
# Case 4: Live PID file, policy=raise → script exits 2 with stderr; PID file untouched.
# -----------------------------------------------------------------------------
P4=$(mk_project)
mk_fixture "$P4/wrapper.sh" "case4" "raise"
mkdir -p "$P4/$WOW_PROCESS_DIR_TPL"
echo "$$" > "$P4/$WOW_PROCESS_DIR_TPL/case4-r1.pid"
ORIGINAL_CONTENT=$(cat "$P4/$WOW_PROCESS_DIR_TPL/case4-r1.pid")
set +e
ERR4=$(WOW_ROOT="$P4" WOW_ROLE="r1" bash "$P4/wrapper.sh" 2>&1 >/dev/null)
EXIT_CODE=$?
set -e 2>/dev/null || true
NEW_CONTENT=$(cat "$P4/$WOW_PROCESS_DIR_TPL/case4-r1.pid")
assert_eq        "case-4-raise-exit-2"      "2"                 "$EXIT_CODE"
assert_eq        "case-4-pidfile-untouched" "$ORIGINAL_CONTENT" "$NEW_CONTENT"
assert_contains  "case-4-stderr-message"    "refusing to spawn" "$ERR4"
rm -rf "$P4"

# -----------------------------------------------------------------------------
# Case 5: Clean exit → trap removes PID file.
# -----------------------------------------------------------------------------
P5=$(mk_project)
mk_fixture "$P5/wrapper.sh" "case5" "kill"
WOW_ROOT="$P5" WOW_ROLE="r1" bash "$P5/wrapper.sh" >/dev/null 2>&1 &
PID5=$!
sleep 1
PIDFILE5="$P5/$WOW_PROCESS_DIR_TPL/case5-r1.pid"
[ -f "$PIDFILE5" ] || FAILED_CASES+=("case-5-pre-pidfile-missing")
kill -TERM "$PID5" 2>/dev/null || true
wait "$PID5" 2>/dev/null || true
sleep 1
[ ! -f "$PIDFILE5" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-5-trap-did-not-remove-pidfile"); }
rm -rf "$P5"

# -----------------------------------------------------------------------------
# Case 6: Config file present → variables loaded into the script's environment.
# -----------------------------------------------------------------------------
P6=$(mk_project)
mk_fixture "$P6/wrapper.sh" "case6" "kill"
mkdir -p "$P6/$WOW_PROCESS_DIR_TPL"
cat > "$P6/$WOW_PROCESS_DIR_TPL/case6.conf" << 'EOF'
WOW_PROCESS_TEST_MARKER="loaded-from-conf"
EOF
WOW_ROOT="$P6" WOW_ROLE="r1" bash "$P6/wrapper.sh" >/tmp/case6.out 2>&1 &
PID6=$!
sleep 1
OUT6=$(cat /tmp/case6.out)
assert_contains "case-6-conf-marker-loaded" "fixture-conf-marker:loaded-from-conf" "$OUT6"
kill -TERM "$PID6" 2>/dev/null || true
wait "$PID6" 2>/dev/null || true
rm -rf "$P6" /tmp/case6.out

# -----------------------------------------------------------------------------
# Case 7: Config file absent → defaults apply, no error.
# -----------------------------------------------------------------------------
P7=$(mk_project)
mk_fixture "$P7/wrapper.sh" "case7" "kill"
WOW_ROOT="$P7" WOW_ROLE="r1" bash "$P7/wrapper.sh" >/tmp/case7.out 2>&1 &
PID7=$!
sleep 1
OUT7=$(cat /tmp/case7.out)
assert_contains "case-7-no-conf-default-marker" "fixture-conf-marker:DEFAULT" "$OUT7"
kill -TERM "$PID7" 2>/dev/null || true
wait "$PID7" 2>/dev/null || true
rm -rf "$P7" /tmp/case7.out

# -----------------------------------------------------------------------------
# Per-role PID-file isolation (Story 071 PP FINDING-9 fix): same PURPOSE
# spawned by two different ROLES gets two separate PID files, no
# cross-agent kill.
# -----------------------------------------------------------------------------
P8=$(mk_project)
mk_fixture "$P8/wrapper.sh" "shared-purpose" "kill"
WOW_ROOT="$P8" WOW_ROLE="manager" bash "$P8/wrapper.sh" >/dev/null 2>&1 &
M_PID=$!
sleep 1
WOW_ROOT="$P8" WOW_ROLE="pair-programmer" bash "$P8/wrapper.sh" >/dev/null 2>&1 &
PP_PID=$!
sleep 2
# M's process should still be alive (different role → different PID file).
if kill -0 "$M_PID" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("case-8-per-role-isolation (manager process killed by pair-programmer's spawn)")
fi
[ -f "$P8/$WOW_PROCESS_DIR_TPL/shared-purpose-manager.pid" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-8-manager-pidfile-exists"); }
[ -f "$P8/$WOW_PROCESS_DIR_TPL/shared-purpose-pair-programmer.pid" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_CASES+=("case-8-pp-pidfile-exists"); }
kill -TERM "$M_PID" "$PP_PID" 2>/dev/null || true
wait "$M_PID" 2>/dev/null || true
wait "$PP_PID" 2>/dev/null || true
rm -rf "$P8"

# -----------------------------------------------------------------------------
# Manifest coherence: every purpose in role-process-map matches an actual
# scripts/wow-process/<purpose>.sh, and every script there appears in at
# least one role's array.
# -----------------------------------------------------------------------------
# `?`-flagged conditional entries (slack-bridge-spawn?, slack-events-feed?)
# are slacker-internal — slacker.md owns their re-arm; they don't have
# wrapper scripts. The `?` flag exempts them from the script-exists check
# (matches the rtrimstr predicate post-compact-restore and monitor-spec use).
PURPOSES_IN_MAP=$(jq -r '[.[][]] | unique | .[] | select(endswith("?") | not)' "$ROLE_MAP" | sort -u)
# Helpers (synchronous scripts that are NOT long-running processes armed via
# Monitor) are excluded from the wrapper enumeration. Currently:
#   post-compact-restore.sh — invoked synchronously by the agent's
#     compaction-occurred handler. Reads role-process-map.json;
#     not itself listed in it.
#   monitor-spec.sh, monitor-rearm-record.sh,
#   post-compact-rearm-verify.sh, tracker-armed-purposes.sh — synchronous
#     helpers for the post-compact re-arm flow. Same exclusion
#     rationale as post-compact-restore.sh: invoked by the compaction-occurred
#     handler / SIGINT-recovery path; not themselves wrapped
#     processes the Monitor tool tracks.
#   monitor-pipe.sh, monitor-events-trim.sh — wrapper + trim utility for
#     the Monitor truncation safety net. monitor-pipe.sh is a downstream
#     pipe consumer of every Monitor source's stdout (no role uses it
#     directly as a wrapped process). monitor-events-trim.sh is M's
#     startup-sweep utility, invoked synchronously.
SCRIPTS_ON_DISK=$(find "$ROOT/scripts/wow-process/" -maxdepth 1 -name '*.sh' \
  -exec basename {} \; 2>/dev/null \
  | sed 's|\.sh$||' \
  | grep -vxE 'post-compact-restore|post-compact-rearm-verify|monitor-spec|monitor-rearm-record|tracker-armed-purposes|monitor-pipe|monitor-events-trim' \
  | sort -u)

for p in $PURPOSES_IN_MAP; do
  if echo "$SCRIPTS_ON_DISK" | grep -qx "$p"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("manifest-coherence-purpose-has-script ($p in role-process-map.json but no $p.sh)")
  fi
done

for s in $SCRIPTS_ON_DISK; do
  if echo "$PURPOSES_IN_MAP" | grep -qx "$s"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("manifest-coherence-script-has-role ($s.sh on disk but no role uses it)")
  fi
done

echo "wow-process-pid-uniqueness: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
