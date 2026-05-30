#!/usr/bin/env bash
# Story 160 Layer E + story 173 structure-aware rewrite —
# wow-block-rm-glob-non-manager.sh.
#
# Drives the hook via its PreToolUse stdin envelope. Three groups:
#   ALLOW-set — non-destructive commands that merely CONTAIN rm / glob chars
#               (the false positives story 173 fixes) + the hook's own
#               recommended `find -delete` escape hatch -> must ALLOW.
#   BLOCK-set — a genuine rm/rmdir/unlink (or `xargs rm`) in command position
#               with a glob in its pipeline -> must BLOCK. Includes the R2-R7
#               multiline / continuation / pipe / comment regression rows that
#               closed real fork-bomb holes during plan review.
#   M-exempt  — a manager session running `rm *` ALLOWs, resolved through the
#               REAL whats-my-role (ps-shim + marker seam, not a role stub), so
#               the worktree-cwd M-exemption repair is exercised end-to-end.
#
# Each meaningful assertion carries a `# RED-WITHOUT:` line naming the revert
# patch under tests/.red-without/ that flips it RED (dogfood of story 169's
# convention; confirmed manually here since 169's lint may merge later).

set -u
PASS=0; FAIL=0; FAILED_CASES=()

REAL_WOW_LOCATE=$(command -v wow-locate 2>/dev/null || true)
if [ -z "$REAL_WOW_LOCATE" ]; then
  echo "SKIP: wow-locate not on PATH" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/scripts/hooks/wow-block-rm-glob-non-manager.sh"

# Drive the hook with a whats-my-role ROLE STUB (detector matrix; role incidental).
run_hook_stub() {
  local cmd="$1" role="$2"
  local STUB; STUB=$(mktemp -d)
  cat > "$STUB/wow-locate" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "scripts/whats-my-role.sh" ]; then echo "$STUB/whats-my-role.sh"; exit 0; fi
exec "$REAL_WOW_LOCATE" "\$@"
EOF
  chmod +x "$STUB/wow-locate"
  cat > "$STUB/whats-my-role.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "whats-my-role" ]; then echo "$role"; fi
EOF
  chmod +x "$STUB/whats-my-role.sh"
  printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')" \
    | PATH="$STUB:$PATH" bash "$HOOK"
  rm -rf "$STUB"
}

# Drive the hook through the REAL whats-my-role resolution: wow-locate -> the
# WORKTREE's (fixed) whats-my-role.sh; a ps shim fabricates a claude ancestor at
# PID 99999 so wow_find_claude_pid resolves there; a manager marker is planted in
# a git fixture's main-repo .claude/ keyed to 99999. Exercises hook ->
# whats-my-role -> PPID-walk -> git-common-dir MARKER_DIR -> marker read ->
# exemption (story 173 M-exemption repair end-to-end).
run_hook_real_manager() {
  local cmd="$1"
  local STUB FIX; STUB=$(mktemp -d); FIX=$(mktemp -d)
  ( cd "$FIX" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$FIX/.claude/.session-role-by-claude-pid"
  printf '%s\n' "manager" > "$FIX/.claude/.session-role-by-claude-pid/99999"
  cat > "$STUB/wow-locate" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "scripts/whats-my-role.sh" ]; then echo "$ROOT/scripts/whats-my-role.sh"; exit 0; fi
exec "$REAL_WOW_LOCATE" "\$@"
EOF
  chmod +x "$STUB/wow-locate"
  cat > "$STUB/ps" <<'PSEOF'
#!/usr/bin/env bash
# ps shim: every process's parent is 99999; PID 99999 reports as "claude".
arg_opt=""; arg_pid=""
while [ $# -gt 0 ]; do
  case "$1" in -o) arg_opt="$2"; shift 2 ;; -p) arg_pid="$2"; shift 2 ;; *) shift ;; esac
done
if [ "$arg_pid" = "99999" ]; then
  [ "$arg_opt" = "command=" ] && echo "claude --continue"
  [ "$arg_opt" = "ppid=" ] && echo "1"
else
  [ "$arg_opt" = "command=" ] && echo "bash synthetic"
  [ "$arg_opt" = "ppid=" ] && echo "99999"
fi
PSEOF
  chmod +x "$STUB/ps"
  ( cd "$FIX" && printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')" \
      | PATH="$STUB:$PATH" bash "$HOOK" )
  rm -rf "$STUB" "$FIX"
}

assert_blocked() {
  local name="$1" out="$2"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name should be BLOCKED (got '$out')")
  fi
}

assert_allowed() {
  local name="$1" out="$2"
  if [ -z "$out" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name should be ALLOWED (got '$out')")
  fi
}

# ============================== ALLOW-set ====================================
# RED-WITHOUT: .red-without/revert-remover-gate.patch -> echo "rm *" re-blocks
assert_allowed "echo \"rm *\" (echo not a remover)" "$(run_hook_stub 'echo "rm *"' senior-developer)"
# RED-WITHOUT: .red-without/revert-remover-gate.patch -> grep 'rm.*' re-blocks
assert_allowed "grep -E 'rm.*x' (grep not a remover)" "$(run_hook_stub "grep -E 'rm.*x' file" senior-developer)"
# RED-WITHOUT: .red-without/revert-remover-gate.patch -> git add glob re-blocks
assert_allowed "git add 'rm-cache/*' (git not a remover)" "$(run_hook_stub "git add 'rm-cache/*'" senior-developer)"
# RED-WITHOUT: .red-without/revert-remover-gate.patch -> rm+echo glob re-blocks
assert_allowed "rm specific.txt && echo \"cleaned *\" (glob not in rm pipeline)" "$(run_hook_stub 'rm specific.txt && echo "cleaned *"' senior-developer)"
# RED-WITHOUT: .red-without/revert-remover-gate.patch -> /bin/echo glob re-blocks
assert_allowed "/bin/echo \"rm *\" (basename echo, not a remover)" "$(run_hook_stub '/bin/echo "rm *"' senior-developer)"
# RED-WITHOUT: .red-without/revert-remover-gate.patch -> find -delete re-blocks
assert_allowed "find -name '*.log' -delete (hook's recommended escape; not blocked)" "$(run_hook_stub "find ./tmp -type f -name '*.log' -delete" senior-developer)"
# baseline guards (no glob -> unconditionally allowed; no RED-WITHOUT applicable)
assert_allowed "git add -A (no glob, no remover-glob)" "$(run_hook_stub 'git add -A' senior-developer)"
assert_allowed "rm -f path/specific-file (remover, no glob)" "$(run_hook_stub 'rm -f path/specific-file' senior-developer)"

# ============================== BLOCK-set ====================================
# RED-WITHOUT: .red-without/revert-core-detection.patch -> rm *.txt slips
OUT=$(run_hook_stub 'rm *.txt' senior-developer)
assert_blocked "rm *.txt" "$OUT"
if printf '%s' "$OUT" | jq -e '.reason | contains("nudge")' >/dev/null 2>&1; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("block reason should mention M-nudge bypass")
fi
# RED-WITHOUT: .red-without/revert-core-detection.patch -> rm foo/[abc]* slips
assert_blocked "rm foo/[abc]*" "$(run_hook_stub 'rm foo/[abc]*' senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> ls; rm bar/* slips
assert_blocked "ls; rm bar/* (remover in 2nd statement)" "$(run_hook_stub 'ls; rm bar/*' senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> find|xargs rm slips
assert_blocked "find . -name '*.tmp' | xargs rm (xargs path)" "$(run_hook_stub "find . -name '*.tmp' | xargs rm" senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> rm -rf build/* slips
assert_blocked "rm -rf build/*" "$(run_hook_stub 'rm -rf build/*' senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> /bin/rm *.txt slips
assert_blocked "/bin/rm *.txt (basename remover)" "$(run_hook_stub '/bin/rm *.txt' senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> FOO=1 rm *.txt slips
assert_blocked "FOO=1 rm *.txt (env-prefix)" "$(run_hook_stub 'FOO=1 rm *.txt' senior-developer)"

# --- R2-R7 multiline / continuation / pipe / comment regression rows ---
# RED-WITHOUT: .red-without/revert-newline-normalization.patch -> multiline rm slips
assert_blocked "multiline: ls<nl>rm bar/*" "$(run_hook_stub $'ls\nrm bar/*' senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> R3 slips (shlex natively joins \<nl>, so only full-detection-off flips it; step 1 is belt-and-suspenders)
assert_blocked "R3 backslash-cont: rm \\<nl>*.txt" "$(run_hook_stub $'rm \\\n*.txt' senior-developer)"
# RED-WITHOUT: .red-without/revert-newline-normalization.patch -> R4a mid-token cont slips
assert_blocked "R4a mid-token cont: r\\<nl>m *.txt" "$(run_hook_stub $'r\\\nm *.txt' senior-developer)"
# RED-WITHOUT: .red-without/revert-newline-normalization.patch -> R4b /bin mid-token slips
assert_blocked "R4b /bin/r\\<nl>m *.txt" "$(run_hook_stub $'/bin/r\\\nm *.txt' senior-developer)"
# RED-WITHOUT: .red-without/revert-core-detection.patch -> R5 slips (shlex eats the post-| newline as whitespace, so only full-detection-off flips it; step 2 is belt-and-suspenders)
assert_blocked "R5 pipe-cont: find |<nl>xargs rm" "$(run_hook_stub $'find . -name \x27*.tmp\x27 |\nxargs rm' senior-developer)"
# RED-WITHOUT: .red-without/revert-newline-normalization.patch -> R6a comment-line slips
assert_blocked "R6a comment-line: ls<nl>#c<nl>rm bar/*" "$(run_hook_stub $'ls\n# cleanup\nrm bar/*' senior-developer)"
# RED-WITHOUT: .red-without/revert-newline-normalization.patch -> R6b pipe+comment-line slips
assert_blocked "R6b pipe+comment-line: find |<nl>#c<nl>xargs rm" "$(run_hook_stub $'find . -name \x27*.tmp\x27 |\n# pipe it\nxargs rm' senior-developer)"
# RED-WITHOUT: .red-without/revert-newline-normalization.patch -> R7 inline-comment-after-pipe slips
assert_blocked "R7 inline-comment-after-pipe: find | #c<nl>xargs rm" "$(run_hook_stub $'find . -name \x27*.tmp\x27 | # cleanup\nxargs rm' senior-developer)"

# ============================== M-exemption ==================================
# RED-WITHOUT: revert whats-my-role.sh:ROOT to `git rev-parse --show-toplevel`
#   -> from a worktree cwd MARKER_DIR misses the marker, role='' , rm * blocks.
assert_allowed "manager + rm * (M exempt, real resolution)" "$(run_hook_real_manager 'rm *')"

echo ""
echo "block-rm-glob: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
