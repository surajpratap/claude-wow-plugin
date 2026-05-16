#!/usr/bin/env bash
# Gating tests for the wow-attention-notify.sh Notification hook (Story 081).
# Asserts: non-manager role → silent no-op; marker absent → silent; stale
# marker → no play + marker cleared; fresh marker + manager → play invoked.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # = plugin/
HOOK="$REPO_ROOT/scripts/hooks/wow-attention-notify.sh"
FAIL=0
fail() { echo "ERROR: $1" >&2; FAIL=1; }

[ -f "$HOOK" ] || { echo "ERROR: hook not found: $HOOK" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/plugin/bin" \
         "$SANDBOX/project/.claude/.session-role-by-claude-pid" \
         "$SANDBOX/project/implementations"
SENTINEL="$SANDBOX/played"
# Stub player — records that the play path ran instead of emitting audio.
cat > "$SANDBOX/plugin/bin/wow-attention" <<EOF
#!/usr/bin/env bash
echo played >> "$SENTINEL"
EOF
chmod +x "$SANDBOX/plugin/bin/wow-attention"

# The hook reads $PPID for the session PID. When this test script runs
# 'bash "$HOOK"' directly, the hook's parent is this script — so its $PPID
# is this script's own PID ($$). Name the role marker accordingly.
ROLE_MARKER="$SANDBOX/project/.claude/.session-role-by-claude-pid/$$"
ATTN="$SANDBOX/project/implementations/.attention-requested"

reset() { rm -f "$ROLE_MARKER" "$ATTN" "$SENTINEL"; }
run_hook() {
  CLAUDE_PLUGIN_ROOT="$SANDBOX/plugin" CLAUDE_PROJECT_DIR="$SANDBOX/project" \
    bash "$HOOK" </dev/null
}

# Case 1 — role marker absent → silent no-op.
reset
touch "$ATTN"
run_hook
[ ! -f "$SENTINEL" ] || fail "case 1: played despite no role marker"

# Case 2 — non-manager role → silent no-op, attention marker untouched.
reset
echo senior-developer > "$ROLE_MARKER"
touch "$ATTN"
run_hook
[ ! -f "$SENTINEL" ] || fail "case 2: played for a non-manager role"
[ -e "$ATTN" ]       || fail "case 2: non-manager run consumed the marker"

# Case 3 — manager role, no attention marker → silent no-op.
reset
echo manager > "$ROLE_MARKER"
run_hook
[ ! -f "$SENTINEL" ] || fail "case 3: played with no attention marker"

# Case 4 — manager role, stale marker (mtime > 15 min) → no play, marker cleared.
reset
echo manager > "$ROLE_MARKER"
touch "$ATTN"
touch -t 202001010000 "$ATTN"
run_hook
[ ! -f "$SENTINEL" ] || fail "case 4: played for a stale marker"
[ ! -e "$ATTN" ]     || fail "case 4: stale marker was not cleared"

# Case 5 — manager role, fresh marker → play invoked, marker consumed.
reset
echo manager > "$ROLE_MARKER"
touch "$ATTN"
run_hook
[ -f "$SENTINEL" ] || fail "case 5: fresh marker + manager did not invoke the player"
[ ! -e "$ATTN" ]   || fail "case 5: marker was not consumed after play"

if [ "$FAIL" -ne 0 ]; then
  echo "attention-notify-hook: FAIL" >&2
  exit 1
fi
echo "attention-notify-hook: PASS"
exit 0
