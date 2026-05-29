#!/usr/bin/env bash
# Story 158 — memory ↔ learnings consolidation.
#
# Usage:
#   bash consolidate-memory.sh <role>
#
# Walks CC's per-project memory dir + migrates entries the role can claim
# into `implementations/learnings/<role>.md` with provenance + dedup. Ambiguous
# entries (no role signal) append to a triage file the human reviews.
#
# Stdout: JSON summary {role, path, entries_added, entries_skipped, triage_count}.
# Caller (slash command / startup phase / retro nudge) emits `learnings-consolidated`
# via MCP using this stdout as the payload.

set -u

ROLE="${1:-}"
case "$ROLE" in
  manager|senior-developer|pair-programmer|tester|slacker) ;;
  *) echo "[consolidate-memory] invalid role: '$ROLE'" >&2
     echo "Valid: manager senior-developer pair-programmer tester slacker" >&2
     exit 2 ;;
esac

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LEARNINGS_FILE="${WOW_ROOT}/implementations/learnings/${ROLE}.md"
TRIAGE_FILE="${WOW_ROOT}/implementations/learnings/.consolidate-needs-triage.md"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECT_ENCODED=$(echo "$WOW_ROOT" | sed 's|/|-|g')
MEMORY_DIR="${CLAUDE_CONFIG_DIR}/projects/${PROJECT_ENCODED}/memory"

ENTRIES_ADDED=0
ENTRIES_SKIPPED=0
TRIAGE_COUNT=0
TODAY_SECTION="## From memory consolidation ($(date -u +%Y-%m-%d))"

emit_summary() {
  # Bug 0005 fix: pass values via env vars, not interpolated into the python
  # source. Defense-in-depth: even though ROLE is enum-validated and counts
  # are integers, env-var passing is the consistent safe pattern across all
  # python3 invocations in this script.
  ROLE_E="$ROLE" PATH_E="$LEARNINGS_FILE" ADDED_E="$ENTRIES_ADDED" \
  SKIPPED_E="$ENTRIES_SKIPPED" TRIAGE_E="$TRIAGE_COUNT" \
  python3 - <<'PY'
import json, os
print(json.dumps({
    'role': os.environ['ROLE_E'],
    'path': os.environ['PATH_E'],
    'entries_added': int(os.environ['ADDED_E']),
    'entries_skipped': int(os.environ['SKIPPED_E']),
    'triage_count': int(os.environ['TRIAGE_E']),
}))
PY
}

# Memory dir absent → no-op + emit summary (always-emit per round-3 fix).
if [ ! -d "$MEMORY_DIR" ]; then
  emit_summary
  exit 0
fi

# Attribution heuristic. Stdout: "in-scope" | "other-role:<role>" | "ambiguous".
# Priority a > b > c > d when multiple heuristics fire and disagree → highest
# priority wins; conflict noted in triage.
attribute_role() {
  local file="$1"
  local fm_role body filename
  # Bug 0005 fix: pass file path via env, not interpolated into python source.
  fm_role=$(FILE_E="$file" python3 - <<'PY' 2>/dev/null
import sys, re, os
with open(os.environ['FILE_E'], 'r', encoding='utf-8') as f:
    raw = f.read()
m = re.match(r'^---\n(.*?)\n---', raw, re.DOTALL)
if not m:
    print('')
    sys.exit(0)
fm = m.group(1)
for line in fm.split('\n'):
    stripped = line.strip()
    if stripped.startswith('role:'):
        print(stripped.split(':', 1)[1].strip())
        sys.exit(0)
    if stripped == 'metadata:':
        continue
    if line.startswith('  role:'):
        print(line.split(':', 1)[1].strip())
        sys.exit(0)
print('')
PY
)

  body=$(awk 'BEGIN{p=0} /^---$/{c++; if(c==2){p=1; next}} p' "$file")
  filename=$(basename "$file")

  # Heuristic a: frontmatter
  if [ -n "$fm_role" ]; then
    if [ "$fm_role" = "$ROLE" ]; then echo "in-scope:a"; return; fi
    echo "other-role:$fm_role"; return
  fi
  # Heuristic b: explicit [role: X] or (role: X) in body
  local b_role
  b_role=$(printf '%s' "$body" | grep -oE '[\[\(]role: (manager|senior-developer|pair-programmer|tester|slacker)[\]\)]' | head -1 | sed -E 's/[\[\(]role: ([a-z-]+)[\]\)]/\1/')
  if [ -n "$b_role" ]; then
    if [ "$b_role" = "$ROLE" ]; then echo "in-scope:b"; return; fi
    echo "other-role:$b_role"; return
  fi
  # Heuristic c: body mentions exactly one role
  local c_roles
  c_roles=$(printf '%s' "$body" | grep -oE '\b(manager|senior-developer|pair-programmer|tester|slacker)\b' | sort -u | tr '\n' ' ')
  local c_count=0
  for r in $c_roles; do c_count=$((c_count+1)); done
  if [ "$c_count" = "1" ]; then
    local only_role
    only_role=$(echo "$c_roles" | awk '{print $1}')
    if [ "$only_role" = "$ROLE" ]; then echo "in-scope:c"; return; fi
    echo "other-role:$only_role"; return
  fi
  # Heuristic d: filename prefix
  case "$filename" in
    "${ROLE}-"*) echo "in-scope:d"; return ;;
    manager-*|senior-developer-*|pair-programmer-*|tester-*|slacker-*)
      local d_role
      d_role=$(echo "$filename" | sed -E 's/^(manager|senior-developer|pair-programmer|tester|slacker)-.*$/\1/')
      echo "other-role:$d_role"; return ;;
  esac
  # None matched
  echo "ambiguous"
}

is_consolidated() {
  # Bug 0005 fix: pass file path via env.
  FILE_E="$1" python3 - <<'PY'
import re, sys, os
with open(os.environ['FILE_E'], 'r', encoding='utf-8') as f:
    raw = f.read()
m = re.match(r'^---\n(.*?)\n---', raw, re.DOTALL)
if m and re.search(r'^consolidated-into:', m.group(1), re.MULTILINE):
    sys.exit(0)
sys.exit(1)
PY
}

# Atomic write helper: writes content from stdin to dest via tmp+rename.
atomic_write() {
  local dest="$1"
  local tmp="${dest}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$dest")"
  cat > "$tmp"
  mv -f "$tmp" "$dest"
  chmod 0644 "$dest" 2>/dev/null || true
}

extract_name() {
  # Bug 0005 fix: pass file path via env.
  FILE_E="$1" python3 - <<'PY'
import re, sys, os
with open(os.environ['FILE_E'], 'r', encoding='utf-8') as f:
    raw = f.read()
m = re.match(r'^---\n(.*?)\n---', raw, re.DOTALL)
if not m: print(''); sys.exit(0)
for line in m.group(1).split('\n'):
    s = line.strip()
    if s.startswith('name:'):
        print(s.split(':', 1)[1].strip())
        sys.exit(0)
print('')
PY
}

extract_body() {
  awk 'BEGIN{p=0} /^---$/{c++; if(c==2){p=1; next}} p' "$1"
}

mark_consolidated() {
  # Bug 0005 fix: pass file path + learnings path via env, not interpolated.
  local file="$1"
  FILE_E="$file" LEARNINGS_E="$LEARNINGS_FILE" python3 - <<'PY'
import sys, re, os
file_path = os.environ['FILE_E']
learnings_path = os.environ['LEARNINGS_E']
with open(file_path, 'r', encoding='utf-8') as f:
    raw = f.read()
m = re.match(r'^(---\n)(.*?)(\n---\n)(.*)$', raw, re.DOTALL)
if not m:
    new = '---\nconsolidated-into: ' + learnings_path + '\n---\n\n' + raw
else:
    fm = m.group(2)
    if 'consolidated-into:' in fm:
        sys.exit(0)
    fm = fm + '\nconsolidated-into: ' + learnings_path
    new = m.group(1) + fm + m.group(3) + m.group(4)
with open(file_path, 'w', encoding='utf-8') as f:
    f.write(new)
PY
}

dedup_present() {
  # Returns 0 if learnings file already has H3 heading with this name slug.
  local name="$1"
  [ -f "$LEARNINGS_FILE" ] || return 1
  grep -qF "### $name" "$LEARNINGS_FILE"
}

append_to_learnings() {
  local name="$1" body="$2" source_file="$3"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Bug 0005 fix (HIGH): pass ALL untrusted content (body, name) and all
  # constructed paths via env vars instead of interpolating into the python
  # source string. Earlier '''$body''' interpolation was vulnerable to
  # triple-quote breakout if a memory file's body contained ''' or other
  # python escapes — that's the headline RCE vector the security review
  # flagged.
  BODY_E="$body" NAME_E="$name" PATH_E="$LEARNINGS_FILE" \
  SECTION_E="$TODAY_SECTION" \
  FOOTER_E="<!-- consolidated from memory: $(basename "$source_file") at $now -->" \
  ROLE_E="$ROLE" \
  python3 - <<'PY'
import os
body = os.environ['BODY_E']
name = os.environ['NAME_E']
path = os.environ['PATH_E']
section = os.environ['SECTION_E']
footer = os.environ['FOOTER_E']
role = os.environ['ROLE_E']
heading = '### ' + name

if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as f:
        raw = f.read()
else:
    raw = '# ' + role + ' learnings\n\n'

if section not in raw:
    if not raw.endswith('\n'):
        raw += '\n'
    raw += '\n' + section + '\n'

raw += '\n' + heading + '\n\n' + body.strip() + '\n\n' + footer + '\n'

tmp = path + '.tmp.' + str(os.getpid())
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(raw)
os.replace(tmp, path)
os.chmod(path, 0o644)
PY
}

append_triage() {
  local file="$1" reason="$2"
  local snippet
  snippet=$(awk 'BEGIN{p=0} /^---$/{c++; if(c==2){p=1; next}} p' "$file" | head -3 | sed 's/^/  > /')
  mkdir -p "$(dirname "$TRIAGE_FILE")"
  {
    echo ""
    echo "### $(basename "$file")  (role=$ROLE attempted at $(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo "Reason: $reason"
    echo "Excerpt:"
    echo "$snippet"
  } >> "$TRIAGE_FILE"
  chmod 0644 "$TRIAGE_FILE" 2>/dev/null || true
}

# Inventory: every *.md under MEMORY_DIR.
shopt -s nullglob
for memory_file in "$MEMORY_DIR"/*.md; do
  if is_consolidated "$memory_file"; then
    ENTRIES_SKIPPED=$((ENTRIES_SKIPPED+1))
    continue
  fi
  verdict=$(attribute_role "$memory_file")
  case "$verdict" in
    in-scope:*)
      name=$(extract_name "$memory_file")
      if [ -z "$name" ]; then
        name=$(basename "$memory_file" .md)
      fi
      if dedup_present "$name"; then
        mark_consolidated "$memory_file"
        ENTRIES_SKIPPED=$((ENTRIES_SKIPPED+1))
        if [ "${WOW_DROP_CONSOLIDATED_MEMORY:-0}" = "1" ]; then
          rm -f "$memory_file"
        fi
        continue
      fi
      body=$(extract_body "$memory_file")
      append_to_learnings "$name" "$body" "$memory_file"
      mark_consolidated "$memory_file"
      if [ "${WOW_DROP_CONSOLIDATED_MEMORY:-0}" = "1" ]; then
        rm -f "$memory_file"
      fi
      ENTRIES_ADDED=$((ENTRIES_ADDED+1))
      ;;
    other-role:*)
      # Out of scope for this role's run; another role's invocation will pick up.
      :
      ;;
    ambiguous)
      append_triage "$memory_file" "no role signal"
      TRIAGE_COUNT=$((TRIAGE_COUNT+1))
      ;;
  esac
done
shopt -u nullglob

emit_summary
