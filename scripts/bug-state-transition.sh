#!/usr/bin/env bash
# Story 159 — bug state-transition helper. Atomic state change against
# the state machine in commands/_agent-protocol.md. Refuses illegal
# transitions. Updates required markers + appends a `## State log` line.
#
# Usage:
#   bug-state-transition.sh <bug-id> <new-status> --agent-id <id> \
#     [--pr-url <url>] [--fixed-in <v>] [--duplicate-of <id>] [--reason <text>]

set -u

if [ "$#" -lt 2 ]; then
  echo "Usage: bug-state-transition.sh <bug-id> <new-status> --agent-id <id> [...]" >&2
  exit 2
fi

BUG_ID="$1"; NEW_STATUS="$2"; shift 2

AGENT_ID=""
PR_URL=""
FIXED_IN=""
DUPLICATE_OF=""
REASON=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent-id)     AGENT_ID="$2"; shift 2 ;;
    --pr-url)       PR_URL="$2"; shift 2 ;;
    --fixed-in)     FIXED_IN="$2"; shift 2 ;;
    --duplicate-of) DUPLICATE_OF="$2"; shift 2 ;;
    --reason)       REASON="$2"; shift 2 ;;
    *) echo "[bug-state-transition] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$AGENT_ID" ]; then
  echo "[bug-state-transition] --agent-id required" >&2
  exit 2
fi

case "$NEW_STATUS" in
  triaged|fixing|fixed|verified|closed|wont-fix|duplicate) ;;
  *) echo "[bug-state-transition] bad new-status '$NEW_STATUS' (triaged|fixing|fixed|verified|closed|wont-fix|duplicate)" >&2; exit 2 ;;
esac

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BUGS_DIR="${WOW_ROOT}/implementations/bugs"

BUG_FILE=""
for f in "$BUGS_DIR/${BUG_ID}-"*.md; do
  if [ -f "$f" ]; then BUG_FILE="$f"; break; fi
done
if [ -z "$BUG_FILE" ]; then
  echo "[bug-state-transition] no bug file matching id '$BUG_ID' in $BUGS_DIR" >&2
  exit 3
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

BUG_FILE_E="$BUG_FILE" \
BUG_ID_E="$BUG_ID" NEW_STATUS_E="$NEW_STATUS" AGENT_ID_E="$AGENT_ID" \
PR_URL_E="$PR_URL" FIXED_IN_E="$FIXED_IN" DUPLICATE_OF_E="$DUPLICATE_OF" \
REASON_E="$REASON" NOW_E="$NOW" \
python3 - <<'PY'
import os, re, sys

path = os.environ['BUG_FILE_E']
new_status = os.environ['NEW_STATUS_E']
agent_id = os.environ['AGENT_ID_E']
now = os.environ['NOW_E']
pr_url = os.environ['PR_URL_E']
fixed_in = os.environ['FIXED_IN_E']
duplicate_of = os.environ['DUPLICATE_OF_E']
reason = os.environ['REASON_E']

with open(path, 'r', encoding='utf-8') as f:
    raw = f.read()

m = re.search(r'<!--\s*status:\s*([a-z-]+)\s*-->', raw)
if not m:
    print(f"[bug-state-transition] no status marker in {path}", file=sys.stderr)
    sys.exit(3)
cur = m.group(1)

LEGAL = {
    'filed':     {'triaged', 'wont-fix', 'duplicate'},
    'triaged':   {'fixing', 'wont-fix', 'duplicate'},
    'fixing':    {'fixed'},
    'fixed':     {'verified'},
    'verified':  {'closed'},
    'closed':    set(),
    'wont-fix':  set(),
    'duplicate': set(),
}
if new_status not in LEGAL.get(cur, set()):
    print(f"[bug-state-transition] illegal transition '{cur}' -> '{new_status}' (legal from '{cur}': {sorted(LEGAL.get(cur, set()))})", file=sys.stderr)
    sys.exit(4)

required_extra = {
    'triaged':   [('triaged-by', agent_id)],
    'fixing':    [('fixing-by', agent_id)],
    'fixed':     [('fixed-by', agent_id)],
    'verified':  [('verified-by', agent_id)],
    'closed':    [('closed-at', now)],
    'wont-fix':  [('closed-at', now)],
    'duplicate': [('closed-at', now), ('duplicate-of', duplicate_of)],
}
extras = list(required_extra.get(new_status, []))
if new_status == 'fixed':
    if not pr_url:
        print(f"[bug-state-transition] --pr-url required for transition to 'fixed'", file=sys.stderr)
        sys.exit(5)
    if not fixed_in:
        print(f"[bug-state-transition] --fixed-in required for transition to 'fixed'", file=sys.stderr)
        sys.exit(5)
    extras += [('pr-url', pr_url), ('fixed-in', fixed_in)]
if new_status == 'duplicate' and not duplicate_of:
    print(f"[bug-state-transition] --duplicate-of required for transition to 'duplicate'", file=sys.stderr)
    sys.exit(5)

new_text = re.sub(
    r'<!--\s*status:\s*[a-z-]+\s*-->',
    f'<!-- status: {new_status} -->',
    raw, count=1,
)

for key, val in extras:
    pat = r'<!--\s*' + re.escape(key) + r':[^>]*-->'
    if re.search(pat, new_text):
        new_text = re.sub(pat, f'<!-- {key}: {val} -->', new_text, count=1)
    else:
        new_text = re.sub(
            r'(<!--\s*status:[^>]*-->\n)',
            r'\1' + f'<!-- {key}: {val} -->\n',
            new_text, count=1,
        )

log_line = f'- {now} {agent_id} moved status from {cur} to {new_status}'
if reason:
    log_line += f' ({reason})'
if '## State log' not in new_text:
    if not new_text.endswith('\n'):
        new_text += '\n'
    new_text += '\n## State log\n\n'
new_text = new_text.rstrip() + '\n' + log_line + '\n'

tmp = path + f'.tmp.{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(new_text)
os.replace(tmp, path)
os.chmod(path, 0o644)
print(f"[bug-state-transition] {os.path.basename(path)}: {cur} -> {new_status}")
PY
RC=$?
# FINDING-44 follow-up: exit early on python3 failure so a refused/illegal
# transition does NOT proceed to bus emit. The script must propagate the
# python exit code (3=missing file/status, 4=illegal transition, 5=missing
# required arg).
if [ "$RC" -ne 0 ]; then exit "$RC"; fi

# Bug 0006 (P0) + FINDING-44 fix: auto-emit the corresponding bus message
# via the MCP CLI for fixing / fixed / closed transitions. Uses the
# POSITIONAL `bus_emit` CLI form (server.py __main__ only dispatches on
# argv[1]=="bus_emit"; the prior `--exec bus-emit` shape was silently inert
# because argv[1]=="--exec" falls through to the stdio JSON-RPC server).
# Construct the payload via env-var-passing python3 heredoc (bug 0005
# pattern — no python3 -c bash-interpolation). Do NOT 2>/dev/null swallow
# failures; surface them on stderr so a future CLI break is loud, not
# silent like the inert form was.
case "$NEW_STATUS" in
  fixing|fixed|closed)
    MCP_SERVER=$(wow-locate mcp/claude-wow-server/server.py 2>/dev/null || true)
    if [ -n "$MCP_SERVER" ]; then
      BUG_REF="implementations/bugs/$(basename "$BUG_FILE")"
      PAYLOAD_JSON=$(
        BUG_ID_E="$BUG_ID" BUG_REF_E="$BUG_REF" AGENT_ID_E="$AGENT_ID" \
        python3 - <<'PY'
import json, os
print(json.dumps({
    "bug_id": os.environ["BUG_ID_E"],
    "bug_ref": os.environ["BUG_REF_E"],
    "agent_id": os.environ["AGENT_ID_E"],
}))
PY
      )
      if [ -n "$PAYLOAD_JSON" ]; then
        # T's 163-followup concern: the MCP server's find_project_root
        # walks up from CWD and stops at the first ancestor with
        # .claude-plugin/plugin.json OR .git. When the helper is invoked
        # with CWD inside `plugin/` (which DOES have .claude-plugin/),
        # the walk stops there and writes the bus line to
        # `plugin/implementations/.message-bus.jsonl` instead of the
        # project's actual bus. Explicitly pass CLAUDE_PROJECT_DIR so
        # the MCP CLI lands the emit at the same root the helper used
        # to find the bug file — no ambiguity, regardless of CWD.
        CLAUDE_PROJECT_DIR="$WOW_ROOT" \
        python3 "$MCP_SERVER" bus_emit \
          --from "$AGENT_ID" \
          --to "manager-*" \
          --type "bug-${NEW_STATUS}" \
          --payload-json "$PAYLOAD_JSON" \
          || echo "[bug-state-transition] bus_emit failed for $BUG_ID $NEW_STATUS" >&2
      fi
    fi
    ;;
esac

