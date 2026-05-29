#!/usr/bin/env bash
# Story 152 — directive-doctrine grep lint:
# fails on `ScheduleWakeup.*bus`, `/loop.*bus`, or `while.*true.*bus`
# in commands/**.md UNLESS the hit line OR the line immediately above
# contains the literal HTML-comment marker
# `<!-- allow: pr-comment-burst-collapse -->`. Catches doctrine
# regressions where an agent slips back to a scheduler-style loop for
# bus consumption.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CMDS="$ROOT/commands"
ALLOW_MARKER='<!-- allow: pr-comment-burst-collapse -->'
PATTERN='ScheduleWakeup.*bus|/loop.*bus|while.*true.*bus'

# Helper: lint a single file. Echoes the offending line# for each
# pattern-match without an adjacent allowlist marker.
lint_file() {
  local f="$1"
  awk -v pat="$PATTERN" -v marker="$ALLOW_MARKER" '
    NR==FNR { lines[NR]=$0; total=NR; next }
    BEGIN { }
    {
      next
    }
    END {
      for (i=1; i<=total; i++) {
        if (match(lines[i], pat)) {
          curr = lines[i]
          prev = (i > 1) ? lines[i-1] : ""
          if (index(curr, marker) > 0 || index(prev, marker) > 0) {
            # Allowed
          } else {
            printf "%d: %s\n", i, curr
          }
        }
      }
    }
  ' "$f" "$f"
}

# Run lint on every commands/**.md file
violations=0
violation_files=""
for f in "$CMDS"/*.md; do
  [ -f "$f" ] || continue
  out=$(lint_file "$f")
  if [ -n "$out" ]; then
    violations=$((violations + $(echo "$out" | wc -l | tr -d ' ')))
    violation_files="$violation_files $f"
    echo "VIOLATION in $(basename "$f"):"
    echo "$out"
  fi
done

if [ "$violations" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_CASES+=("$violations scheduler-for-bus violation(s) found in:$violation_files")
fi

# Negative test (regression guard): construct a fixture and assert
# the lint catches it
TMP=$(mktemp -d)
mkdir -p "$TMP/commands"
cat > "$TMP/commands/test-without-marker.md" <<'EOF'
# Bad doctrine
Don't write this:

ScheduleWakeup every 30s to read the bus.

EOF

cat > "$TMP/commands/test-with-marker.md" <<'EOF'
# Good doctrine
<!-- allow: pr-comment-burst-collapse -->
while true; do gh api bus; sleep 2; done

EOF

# Override CMDS for the negative test
LINT_NEG_OUT=""
for f in "$TMP/commands"/*.md; do
  out=$(lint_file "$f")
  [ -n "$out" ] && LINT_NEG_OUT="$LINT_NEG_OUT
$out"
done

# Should catch test-without-marker but NOT test-with-marker
if printf '%s' "$LINT_NEG_OUT" | grep -q "ScheduleWakeup"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("negative-test-1: lint did not catch ScheduleWakeup without marker")
fi
if printf '%s' "$LINT_NEG_OUT" | grep -q "while.*true"; then
  FAIL=$((FAIL+1)); FAILED_CASES+=("negative-test-2: lint flagged a properly-marker'd line (false positive)")
else
  PASS=$((PASS+1))
fi
rm -rf "$TMP"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
