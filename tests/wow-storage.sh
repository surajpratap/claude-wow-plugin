#!/usr/bin/env bash
# Story 016 / Section I — wow-storage.sh helper test.
#
# Each case sets HOME to a fresh mktemp -d and WOW_HOME to $HOME/.wow-kindflow,
# then exercises one slice of the helper's behavior. Cleanup at end via trap.
#
# Pattern mirrors tests/manager-pre-sleep-liveness.sh from sprint 2026-05-01.

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

assert_true() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (assertion failed: $*)")
  fi
}

assert_false() {
  local name="$1"; shift
  if "$@"; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected failure but assertion succeeded: $*)")
  else
    PASS=$((PASS+1))
  fi
}

# Resolve the helper script path (worktree-relative).
HELPER="$(cd "$(dirname "$0")/.." && pwd)/scripts/wow-storage.sh"
if [ ! -f "$HELPER" ]; then
  printf 'wow-storage.sh: helper not found at %s\n' "$HELPER" >&2
  exit 2
fi

# Portable file-mode read (BSD vs GNU stat).
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Each case runs in a subshell so HOME / WOW_HOME / sourced env don't leak.

# Case 1: init creates dir + version file with correct perms.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  [ -d "$WOW_HOME" ] || exit 11
  [ "$(file_mode "$WOW_HOME")" = "700" ] || exit 12
  [ -f "$WOW_HOME/.version" ] || exit 13
  [ "$(cat "$WOW_HOME/.version")" = "1.0.0" ] || exit 14
  rm -rf "$TMPHOME"
)
assert_eq "case-1-init-creates-dir-and-version" "0" "$?"

# Case 2: init is idempotent — second call doesn't change .version mtime.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  MTIME1=$(stat -c '%Y' "$WOW_HOME/.version" 2>/dev/null || stat -f '%m' "$WOW_HOME/.version")
  sleep 1
  wow_storage_init
  MTIME2=$(stat -c '%Y' "$WOW_HOME/.version" 2>/dev/null || stat -f '%m' "$WOW_HOME/.version")
  [ "$MTIME1" = "$MTIME2" ] || exit 21
  rm -rf "$TMPHOME"
)
assert_eq "case-2-init-is-idempotent" "0" "$?"

# Case 3: set then get round-trip.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "xoxb-roundtrip"
  RESULT=$(wow_storage_get slack myproj token)
  [ "$RESULT" = "xoxb-roundtrip" ] || exit 31
  rm -rf "$TMPHOME"
)
assert_eq "case-3-set-then-get-roundtrip" "0" "$?"

# Case 4: file perms are 0600 after set.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "x"
  MODE=$(file_mode "$WOW_HOME/slack/myproj/creds.json")
  [ "$MODE" = "600" ] || exit 41
  rm -rf "$TMPHOME"
)
assert_eq "case-4-file-perms-are-0600" "0" "$?"

# Case 5: dir perms are 0700 (both scope dir and project-key dir).
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "x"
  SCOPE_MODE=$(file_mode "$WOW_HOME/slack")
  KEY_MODE=$(file_mode "$WOW_HOME/slack/myproj")
  [ "$SCOPE_MODE" = "700" ] || exit 51
  [ "$KEY_MODE" = "700" ] || exit 52
  rm -rf "$TMPHOME"
)
assert_eq "case-5-dir-perms-are-0700" "0" "$?"

# Case 6: list shows projects.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack proj1 token "a"
  wow_storage_set slack proj2 token "b"
  LISTED=$(wow_storage_list slack | sort | tr '\n' ' ')
  [ "$LISTED" = "proj1 proj2 " ] || exit 61
  rm -rf "$TMPHOME"
)
assert_eq "case-6-list-shows-projects" "0" "$?"

# Case 7: wipe refuses without --force.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "x"
  wow_storage_wipe slack myproj 2>/dev/null
  RC=$?
  [ "$RC" -ne 0 ] || exit 71
  [ -d "$WOW_HOME/slack/myproj" ] || exit 72
  rm -rf "$TMPHOME"
)
assert_eq "case-7-wipe-refuses-without-force" "0" "$?"

# Case 8: wipe with --force removes.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "x"
  wow_storage_wipe slack myproj --force
  [ ! -d "$WOW_HOME/slack/myproj" ] || exit 81
  rm -rf "$TMPHOME"
)
assert_eq "case-8-wipe-with-force-removes" "0" "$?"

# Case 9: atomic-rename — no .tmp.* file at the cred-file path after set completes.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "x"
  # No .tmp.* siblings at the cred dir.
  STRAYS=$(find "$WOW_HOME/slack/myproj" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$STRAYS" = "0" ] || exit 91
  # Final file exists.
  [ -f "$WOW_HOME/slack/myproj/creds.json" ] || exit 92
  rm -rf "$TMPHOME"
)
assert_eq "case-9-atomic-rename-no-partial" "0" "$?"

# Case 10: get on missing field exits 1.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_set slack myproj token "x"
  wow_storage_get slack myproj nonexistent_field 2>/dev/null
  RC=$?
  [ "$RC" = "1" ] || exit 101
  rm -rf "$TMPHOME"
)
assert_eq "case-10-get-missing-field-exits-1" "0" "$?"

# Case 11: get on missing file exits 1.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  wow_storage_get slack neverwritten token 2>/dev/null
  RC=$?
  [ "$RC" = "1" ] || exit 111
  rm -rf "$TMPHOME"
)
assert_eq "case-11-get-missing-file-exits-1" "0" "$?"

# Case 12: --from-stdin avoids argv leak; round-trips correctly.
(
  TMPHOME=$(mktemp -d)
  export HOME="$TMPHOME"
  export WOW_HOME="$HOME/.wow-kindflow"
  source "$HELPER"
  wow_storage_init
  printf 'xoxb-secret-stdin\n' | wow_storage_set slack myproj token --from-stdin
  RESULT=$(wow_storage_get slack myproj token)
  [ "$RESULT" = "xoxb-secret-stdin" ] || exit 121
  rm -rf "$TMPHOME"
)
assert_eq "case-12-from-stdin-roundtrip" "0" "$?"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "wow-storage: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
