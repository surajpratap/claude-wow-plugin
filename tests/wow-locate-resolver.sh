#!/usr/bin/env bash
# Regression guard for the wow-locate plugin-file resolver (Story 080).
# Asserts: the script exists + is executable; it resolves known plugin files
# to real paths; the project-local .claude/ override takes precedence; no
# command or startup file instructs the agent to find/grep the repo for
# plugin files; the bootstrap rewire is present.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # = plugin/
WOW_LOCATE="$REPO_ROOT/bin/wow-locate"
FAIL=0

fail() { echo "ERROR: $1" >&2; FAIL=1; }

# --- 1. script exists and is executable ---------------------------------
[ -f "$WOW_LOCATE" ] || fail "bin/wow-locate not found"
[ -x "$WOW_LOCATE" ] || fail "bin/wow-locate is not executable"

# --- 2. resolves known plugin files to real files -----------------------
for rel in commands/_agent-protocol.md commands/_manager-startup.md; do
  out="$(bash "$WOW_LOCATE" "$rel" 2>/dev/null)" || { fail "wow-locate $rel exited non-zero"; continue; }
  [ -n "$out" ]   || fail "wow-locate $rel printed nothing"
  [ -f "$out" ]   || fail "wow-locate $rel resolved to a non-file: $out"
done

# --- 3. missing file → non-zero exit + stderr diagnostic ----------------
if bash "$WOW_LOCATE" commands/__definitely_absent__.md >/dev/null 2>&1; then
  fail "wow-locate did not exit non-zero for a missing file"
fi

# --- 3b. project-local .claude/<path> override takes precedence ---------
TMP_OVERRIDE_DIR="$(mktemp -d)"
mkdir -p "$TMP_OVERRIDE_DIR/.claude/commands"
echo "override marker" > "$TMP_OVERRIDE_DIR/.claude/commands/_agent-protocol.md"
ov_out="$(CLAUDE_PROJECT_DIR="$TMP_OVERRIDE_DIR" bash "$WOW_LOCATE" commands/_agent-protocol.md 2>/dev/null)"
[ "$ov_out" = "$TMP_OVERRIDE_DIR/.claude/commands/_agent-protocol.md" ] \
  || fail "wow-locate did not honor the .claude/ project-local override (got: $ov_out)"
rm -rf "$TMP_OVERRIDE_DIR"

# --- 4. no command/startup file tells the agent to search the repo ------
# The bootstrap fallback uses `ls -t .../plugins/cache/...` — an ls glob, not
# find/grep — so this guard targets find/grep search COMMANDS specifically.
DIRECTIVES=(
  "$REPO_ROOT"/commands/manager.md
  "$REPO_ROOT"/commands/senior-developer.md
  "$REPO_ROOT"/commands/pair-programmer.md
  "$REPO_ROOT"/commands/tester.md
  "$REPO_ROOT"/commands/slacker.md
  "$REPO_ROOT"/commands/_startup-common.md
  "$REPO_ROOT"/commands/_manager-startup.md
  "$REPO_ROOT"/commands/_senior-developer-startup.md
  "$REPO_ROOT"/commands/_pair-programmer-startup.md
  "$REPO_ROOT"/commands/_tester-startup.md
  "$REPO_ROOT"/commands/_slacker-startup.md
)
for f in "${DIRECTIVES[@]}"; do
  [ -f "$f" ] || { fail "directive file missing: $f"; continue; }
  if grep -nE 'find[[:space:]].*-name' "$f" >/dev/null 2>&1; then
    fail "$(basename "$f") contains a 'find … -name' search command"
  fi
  if grep -nE 'grep[[:space:]]+-[rR]' "$f" >/dev/null 2>&1; then
    fail "$(basename "$f") contains a recursive grep search command"
  fi
done

# --- 5. all 5 command files carry the wow-locate bootstrap line ----------
for role in manager senior-developer pair-programmer tester slacker; do
  grep -qF 'wow-locate' "$REPO_ROOT/commands/$role.md" \
    || fail "commands/$role.md is missing the wow-locate bootstrap line"
done

# --- 6. startup files + _startup-common.md reference wow-locate ----------
for f in _startup-common.md _manager-startup.md _senior-developer-startup.md \
         _pair-programmer-startup.md _tester-startup.md _slacker-startup.md; do
  grep -qF 'wow-locate' "$REPO_ROOT/commands/$f" \
    || fail "commands/$f does not reference wow-locate"
done

# --- 7. _manager-startup.md step-9 version greps all resolve via wow-locate ---
# PJ_V/MGR_V/ROW_V must each resolve their plugin file via wow-locate, never a
# bare ${ROOT}/ path (Story 082 regression guard — the consumer ${ROOT} has no
# commands/ / docs/ / .claude-plugin/).
MGR_STARTUP="$REPO_ROOT/commands/_manager-startup.md"
for var in PJ_V MGR_V ROW_V; do
  line="$(grep -E "^[[:space:]]*$var=" "$MGR_STARTUP" 2>/dev/null | head -1)"
  [ -n "$line" ] || { fail "_manager-startup.md step 9: $var assignment not found"; continue; }
  case "$line" in
    *wow-locate*) ;;
    *) fail "_manager-startup.md step 9: $var does not resolve its file via wow-locate" ;;
  esac
  case "$line" in
    *'${ROOT}/'*) fail "_manager-startup.md step 9: $var still uses a bare \${ROOT}/ path" ;;
  esac
done

if [ "$FAIL" -ne 0 ]; then
  echo "wow-locate-resolver: FAIL" >&2
  exit 1
fi
echo "wow-locate-resolver: PASS"
exit 0
