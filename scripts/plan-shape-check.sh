#!/usr/bin/env bash
# plan-shape-check.sh — lint plan file(s) for the required `## AC count` section.
#
# Usage: plan-shape-check.sh <plan-file> [<plan-file>...]
#
# Mechanizes the `## AC count` plan-section NIT. Operates on the specific
# file(s) passed (the plan under review). Not a blanket scan of
# implementations/plans/ — many non-draft plans predate the convention, so a
# scan-all gate is non-viable.
#
# A non-draft plan that lacks an `## AC count` heading is an offender. Draft
# plans (line 1 == the exact `<!-- status: drafting -->` marker) are exempt.
# Checks PRESENCE of the section, not the accuracy of the count it states.
#
# Exit: 0 = all passed, 1 = >=1 offender (or unreadable file), 2 = usage error.
# No `set -e` — we collect ALL offenders rather than abort on the first.

set -u

if [ "$#" -lt 1 ]; then
  echo "usage: plan-shape-check.sh <plan-file> [<plan-file>...]" >&2
  exit 2
fi

rc=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "PLAN-SHAPE: file not found — $f" >&2
    rc=1
    continue
  fi
  # Draft exemption: line 1 must equal the exact marker (CR-stripped for CRLF
  # files). Strict equality avoids a too-broad exemption — anything that is not
  # exactly the drafting marker is treated as a non-draft that needs the section.
  line1=$(head -1 "$f" | tr -d '\r')
  if [ "$line1" = "<!-- status: drafting -->" ]; then
    continue
  fi
  # Require an `## AC count` heading. End-anchored (trailing whitespace allowed)
  # so `## AC counted` and similar cannot false-pass.
  if ! grep -Eq '^## AC count[[:space:]]*$' "$f"; then
    echo "PLAN-SHAPE: missing '## AC count' section — $f" >&2
    rc=1
  fi
done

exit "$rc"
