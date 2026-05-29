#!/usr/bin/env bash
# Story 159 — bug schema validator. Walks every implementations/bugs/*.md
# and asserts:
#   • all required markers per the file's current status are present
#   • marker values match the enums (status, severity, priority)
#   • id marker matches filename prefix
#   • reported-at + closed-at are valid ISO-8601
#   • duplicate-of (when present) references an existing bug id
# Exit 0 on all-pass; non-zero with per-file diagnostics on stderr.

set -u

WOW_ROOT="${WOW_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BUGS_DIR="${WOW_ROOT}/implementations/bugs"

if [ ! -d "$BUGS_DIR" ]; then
  exit 0
fi

# Run the validator in a single python3 process (heredoc, no -c interpolation).
BUGS_DIR_E="$BUGS_DIR" python3 - <<'PY'
import os, re, sys
from datetime import datetime

bugs_dir = os.environ['BUGS_DIR_E']
STATUSES = {'filed', 'triaged', 'fixing', 'fixed', 'verified', 'closed', 'wont-fix', 'duplicate'}
SEVERITIES = {'blocker', 'high', 'medium', 'low'}
PRIORITIES = {'P0', 'P1', 'P2', 'P3'}

REQUIRED_AT_FILED = ['status', 'id', 'reporter', 'reported-at', 'severity', 'priority', 'affected-story', 'affected-version']
REQUIRED_ADDED = {
    'triaged':   ['triaged-by'],
    'fixing':    ['fixing-by'],
    'fixed':     ['fixed-by', 'fixed-in', 'pr-url'],
    'verified':  ['verified-by'],
    'closed':    ['closed-at'],
    'wont-fix':  ['closed-at'],
    'duplicate': ['closed-at', 'duplicate-of'],
}

STATUS_ORDER = ['filed', 'triaged', 'fixing', 'fixed', 'verified', 'closed']

def required_for(status):
    req = list(REQUIRED_AT_FILED)
    if status in {'closed', 'wont-fix', 'duplicate'}:
        req += REQUIRED_ADDED[status]
        if status == 'closed':
            for s in ('triaged', 'fixing', 'fixed', 'verified'):
                req += REQUIRED_ADDED[s]
        return req
    if status not in STATUS_ORDER:
        return req
    idx = STATUS_ORDER.index(status)
    for s in STATUS_ORDER[1:idx + 1]:
        req += REQUIRED_ADDED[s]
    return req

def parse_markers(text):
    markers = {}
    for m in re.finditer(r'<!--\s*([a-z-]+):\s*([^>]*?)\s*-->', text):
        markers[m.group(1)] = m.group(2).strip()
    return markers

def valid_iso8601(s):
    if not s:
        return False
    for fmt in ('%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%d'):
        try:
            datetime.strptime(s, fmt)
            return True
        except ValueError:
            pass
    try:
        datetime.fromisoformat(s.replace('Z', '+00:00'))
        return True
    except Exception:
        return False

failures = []
bug_ids_seen = set()
file_to_id = {}

bug_files = sorted(f for f in os.listdir(bugs_dir) if f.endswith('.md') and not f.startswith('.'))
for fname in bug_files:
    fpath = os.path.join(bugs_dir, fname)
    with open(fpath, 'r', encoding='utf-8') as f:
        text = f.read()
    markers = parse_markers(text)
    file_to_id[fname] = markers.get('id', '')
    if markers.get('id'):
        bug_ids_seen.add(markers['id'])

for fname in bug_files:
    fpath = os.path.join(bugs_dir, fname)
    with open(fpath, 'r', encoding='utf-8') as f:
        text = f.read()
    markers = parse_markers(text)
    file_failures = []

    status = markers.get('status', '')
    if status not in STATUSES:
        file_failures.append(f"unknown status enum '{status}' — must be one of {sorted(STATUSES)}")

    sev = markers.get('severity', '')
    if 'severity' in markers and sev not in SEVERITIES:
        file_failures.append(f"unknown severity '{sev}' — must be one of {sorted(SEVERITIES)}")

    pri = markers.get('priority', '')
    if 'priority' in markers and pri not in PRIORITIES:
        file_failures.append(f"unknown priority '{pri}' — must be one of {sorted(PRIORITIES)}")

    if status in STATUSES:
        for req in required_for(status):
            if req not in markers:
                file_failures.append(f"missing required marker '{req}' for status '{status}'")

    file_id = markers.get('id', '')
    m = re.match(r'^(\d{4})-', fname)
    if m and file_id:
        if file_id != m.group(1):
            file_failures.append(f"id marker '{file_id}' does not match filename prefix '{m.group(1)}'")
    elif m and not file_id:
        pass

    for ts_field in ('reported-at', 'closed-at'):
        if ts_field in markers and not valid_iso8601(markers[ts_field]):
            file_failures.append(f"'{ts_field}' is not a valid ISO-8601 timestamp: '{markers[ts_field]}'")

    if status == 'duplicate':
        dup_id = markers.get('duplicate-of', '')
        if dup_id and dup_id not in bug_ids_seen and dup_id != file_id:
            file_failures.append(f"duplicate-of='{dup_id}' references nonexistent bug")

    if file_failures:
        failures.append((fname, file_failures))

if failures:
    print(f"bug-shape-check: {len(failures)} file(s) failed:", file=sys.stderr)
    for fname, errs in failures:
        print(f"  {fname}:", file=sys.stderr)
        for e in errs:
            print(f"    - {e}", file=sys.stderr)
    sys.exit(1)

print(f"bug-shape-check: ok ({len(bug_files)} file(s) validated)")
sys.exit(0)
PY
