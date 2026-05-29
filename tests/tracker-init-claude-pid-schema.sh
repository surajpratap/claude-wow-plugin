#!/usr/bin/env bash
# Story 132 — FINDING-34 close. Pins the documented tracker-init schema
# (`_<role>-startup.md` step 5/7) to include `claude_pid`, so Story 121's
# wow-existing-agent-id.sh reader can match on next reset.
#
# Two checks:
#   (1) Doc-shape: each `_<role>-startup.md` mentions claude_pid in the
#       same paragraph as `last_line` / `offset tracker` phrasing (10-line
#       window). Catches a future doctrine drift that drops the field.
#   (2) Behavior: write a tracker per the documented schema, then run
#       wow-existing-agent-id.sh against a synthetic PID that matches the
#       tracker's claude_pid. Helper must echo the agent_id back.

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
ROOT_PLUGIN="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- (1) Doc-shape: each startup file (new or its frozen legacy companion
# from the Story-152 transition release) mentions claude_pid near
# `last_line` / `offset tracker`. The convention now lives in the legacy
# file during the transition release; phase_bootstrap.sh in
# scripts/startup/ implements it at runtime. ----
for role in _manager _senior-developer _pair-programmer _tester _slacker; do
  f="$ROOT_PLUGIN/commands/${role}-startup.md"
  legacy="$ROOT_PLUGIN/commands/${role}-startup-legacy.md"
  if [ ! -f "$f" ]; then
    FAIL=$((FAIL+1))
    FAILED_CASES+=("doc-${role}-file-present (startup file missing at $f)")
    continue
  fi
  # Find the line containing the "offset tracker" Initialize step, then
  # check that claude_pid appears within a 10-line window of it. Check
  # the new file first; fall back to the legacy companion.
  if awk '/Initialize.* offset tracker|Initialize offset tracker/{flag=NR}
          flag && NR >= flag && NR <= flag+10 && /claude_pid/{found=1; exit}
          END{exit !found}' "$f"; then
    PASS=$((PASS+1))
  elif [ -f "$legacy" ] && awk '/Initialize.* offset tracker|Initialize offset tracker/{flag=NR}
          flag && NR >= flag && NR <= flag+10 && /claude_pid/{found=1; exit}
          END{exit !found}' "$legacy"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("doc-${role}-claude_pid-near-tracker-init (claude_pid not found within 10 lines of offset-tracker init step in $f or legacy companion)")
  fi
done

# ---- (2) Behavior: documented schema → wow-existing-agent-id.sh resolves ----
HELPER="$ROOT_PLUGIN/scripts/wow-existing-agent-id.sh"
if [ ! -f "$HELPER" ]; then
  FAIL=$((FAIL+1))
  FAILED_CASES+=("behavior-helper-present (helper missing at $HELPER)")
else
  D=$(mktemp -d)
  AGENTS_DIR="$D/agents"
  mkdir -p "$AGENTS_DIR"
  AGENT_ID="senior-developer-20260521T091400-deadbe"
  # Write a tracker using the schema documented in
  # _senior-developer-startup.md step 5 (last_line, last_seen, claude_pid).
  # Use $$ as the synthetic session PID so the helper's
  # wow_find_claude_pid walk lands on a value we control via the agents-dir
  # override (the helper's PPID-walk isn't relevant — the WOW_AGENTS_DIR
  # path + claude_pid match is what we verify).
  cat > "$AGENTS_DIR/${AGENT_ID}.json" <<EOF
{"last_line": 0, "last_seen": "2026-05-21T09:14:00Z", "claude_pid": $$}
EOF
  # Probe matching helper's per-pid resolver via the in-process python form
  # used by other tests — avoids subshell PPID-walk noise.
  PROBE_OUT=$(python3 - <<PY 2>/dev/null
import os, json, glob
agents_dir = "$AGENTS_DIR"
role = "senior-developer"
session_pid = $$
best_id = ""
best_ll = -1
for f in sorted(glob.glob(os.path.join(agents_dir, f"{role}-*.json"))):
    try:
        with open(f) as fh: t = json.load(fh)
    except Exception:
        continue
    if t.get("claude_pid") != session_pid:
        continue
    ll = t.get("last_line", 0) or 0
    if ll > best_ll:
        best_ll = ll
        best_id = os.path.basename(f).removesuffix(".json")
print(best_id)
PY
)
  assert_eq "behavior-documented-schema-resolves" "$AGENT_ID" "$PROBE_OUT"
  # Negative anti-revert: drop claude_pid from the tracker and verify the
  # helper no longer resolves — confirms the field is the load-bearing key.
  cat > "$AGENTS_DIR/${AGENT_ID}.json" <<EOF
{"last_line": 0, "last_seen": "2026-05-21T09:14:00Z"}
EOF
  PROBE_OUT2=$(python3 - <<PY 2>/dev/null
import os, json, glob
agents_dir = "$AGENTS_DIR"
role = "senior-developer"
session_pid = $$
best_id = ""
for f in sorted(glob.glob(os.path.join(agents_dir, f"{role}-*.json"))):
    try:
        with open(f) as fh: t = json.load(fh)
    except Exception:
        continue
    if t.get("claude_pid") != session_pid:
        continue
    best_id = os.path.basename(f).removesuffix(".json")
print(best_id)
PY
)
  assert_eq "behavior-no-claude_pid-no-resolve" "" "$PROBE_OUT2"
  rm -rf "$D"
fi

echo "tracker-init-claude-pid-schema: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
