#!/usr/bin/env bash
# Story 159 — bug-emit. Generates a new implementations/bugs/<NNNN>-<slug>.md
# with all `filed`-required markers + empty body sections.
#
# Usage:
#   bug-emit.sh --reporter <id> --severity <enum> --priority <enum> \
#               --affected-story <id|"none"> --affected-version <v> \
#               --title <text>
#
# ID allocation is flock-guarded via fcntl.flock (Python wrapper) so
# concurrent T sessions can't collide on the same NNNN.

set -u

REPORTER=""
SEVERITY=""
PRIORITY=""
AFFECTED_STORY=""
AFFECTED_VERSION=""
TITLE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reporter)         REPORTER="$2"; shift 2 ;;
    --severity)         SEVERITY="$2"; shift 2 ;;
    --priority)         PRIORITY="$2"; shift 2 ;;
    --affected-story)   AFFECTED_STORY="$2"; shift 2 ;;
    --affected-version) AFFECTED_VERSION="$2"; shift 2 ;;
    --title)            TITLE="$2"; shift 2 ;;
    --help|-h)
      sed -n 's/^# //p; s/^#$//p' "$0" | head -15 >&2
      exit 0 ;;
    *) echo "[bug-emit] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Required-arg check.
for f in REPORTER SEVERITY PRIORITY AFFECTED_STORY AFFECTED_VERSION TITLE; do
  if [ -z "$(eval "echo \$$f")" ]; then
    echo "[bug-emit] missing required --$(echo "$f" | tr 'A-Z_' 'a-z-')" >&2
    exit 2
  fi
done

# Enum-validate.
case "$SEVERITY" in blocker|high|medium|low) ;; *) echo "[bug-emit] bad severity '$SEVERITY' (blocker|high|medium|low)" >&2; exit 2 ;; esac
case "$PRIORITY" in P0|P1|P2|P3) ;; *) echo "[bug-emit] bad priority '$PRIORITY' (P0|P1|P2|P3)" >&2; exit 2 ;; esac

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BUGS_DIR="${WOW_ROOT}/implementations/bugs"
mkdir -p "$BUGS_DIR"

LOCK_FILE="${BUGS_DIR}/.id-allocation.lock"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Slug from title.
SLUG=$(echo "$TITLE" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | head -c 60 | sed 's/-$//')
if [ -z "$SLUG" ]; then SLUG="untitled"; fi

# fcntl.flock-guarded ID allocation + file write (heredoc, no -c interpolation).
BUGS_DIR_E="$BUGS_DIR" LOCK_E="$LOCK_FILE" \
REPORTER_E="$REPORTER" SEVERITY_E="$SEVERITY" PRIORITY_E="$PRIORITY" \
AFFECTED_STORY_E="$AFFECTED_STORY" AFFECTED_VERSION_E="$AFFECTED_VERSION" \
TITLE_E="$TITLE" SLUG_E="$SLUG" NOW_E="$NOW" \
python3 - <<'PY'
import os, re, sys, fcntl
bugs_dir = os.environ['BUGS_DIR_E']
lock_path = os.environ['LOCK_E']

with open(lock_path, 'w') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    existing = []
    for fname in os.listdir(bugs_dir):
        m = re.match(r'^(\d{4})-', fname)
        if m:
            existing.append(int(m.group(1)))
    next_id = max(existing) + 1 if existing else 1
    nnnn = f'{next_id:04d}'
    slug = os.environ['SLUG_E']
    filename = f'{nnnn}-{slug}.md'
    fpath = os.path.join(bugs_dir, filename)
    if os.path.exists(fpath):
        # Bump again under lock (unlikely; defensive).
        next_id += 1
        nnnn = f'{next_id:04d}'
        filename = f'{nnnn}-{slug}.md'
        fpath = os.path.join(bugs_dir, filename)

    title = os.environ['TITLE_E']
    body = (
        f'<!-- status: filed -->\n'
        f'<!-- id: {nnnn} -->\n'
        f'<!-- reporter: {os.environ["REPORTER_E"]} -->\n'
        f'<!-- reported-at: {os.environ["NOW_E"]} -->\n'
        f'<!-- severity: {os.environ["SEVERITY_E"]} -->\n'
        f'<!-- priority: {os.environ["PRIORITY_E"]} -->\n'
        f'<!-- affected-story: {os.environ["AFFECTED_STORY_E"]} -->\n'
        f'<!-- affected-version: {os.environ["AFFECTED_VERSION_E"]} -->\n'
        f'\n'
        f'# Bug {nnnn} — {title}\n'
        f'\n'
        f'## Reproduction\n'
        f'\n'
        f'<!-- Steps to reproduce, exact command/state, version info -->\n'
        f'\n'
        f'## Expected vs actual\n'
        f'\n'
        f'<!-- What should happen vs what actually happens -->\n'
    )
    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(body)
    print(fpath)
PY
