#!/usr/bin/env bash
# merge-authority-parse.sh — detect a POSSIBLE human merge-authority grant in
# free text and extract a CANDIDATE scope (Story 145). SECURITY-CRITICAL +
# FAIL-CLOSED: this NEVER decides authority — it only proposes a candidate.
# Nothing becomes active merge authority without the human's EXPLICIT confirm
# via M's structured ack (manager.md state machine pending|active|revoked).
#
#   merge-authority-parse.sh "<phrase>"
#
# Prints JSON {candidate:true, scope:<this-sprint|per-item|final-integration|
# unscoped>, raw:"<phrase>"} and exit 0 when the text is an affirmative,
# first/second-person grant. Exit 1 (NOT a candidate) on anything ambiguous:
# negation, question, conditional/prerequisite, or third-party/quoted mention.
# Bias is to REJECT — a false negative just means the human re-phrases; a false
# positive must never even become a pending candidate that M might mishandle.
#
# POSIX ERE only (no \b); BSD/macOS-safe (the 142/144 portability lesson).

set -u
phrase="${1:-}"
[ -n "$phrase" ] || { echo "usage: merge-authority-parse.sh \"<phrase>\"" >&2; exit 2; }

# lowercase (tr is POSIX)
low=$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')

# --- FAIL-CLOSED rejections (checked FIRST) ---------------------------------
# negation: can't / cannot / can not / not / never / no longer / don't / won't / shouldn't / revoke
if printf '%s' "$low" | grep -Eq "can'?t|can[ ]?not|cannot|(^| )not( |$)|never|no longer|do(n'?t| not)|wo(n'?t| not)|should ?n'?t|revoke|rescind|no more"; then
  exit 1
fi
# question: contains a '?' OR a leading interrogative
if printf '%s' "$phrase" | grep -Eq '\?'; then exit 1; fi
if printf '%s' "$low" | grep -Eq '(^| )(can|could|should|may|will|does|is|are) (m|manager|he|she|they|we|you) .*(merge)'; then
  # interrogative-style phrasing without a '?' (e.g. "can m merge to main") — treat as a question, reject
  if ! printf '%s' "$low" | grep -Eq '(m|manager|you) (can|may|is|are) (now )?(merge|authoriz)'; then exit 1; fi
fi
# conditional / prerequisite
if printf '%s' "$low" | grep -Eq '(^| )(once|if|unless|after|when|provided|assuming) '; then exit 1; fi
# third-party / quoted (he/she/they can ...) — only first/second person (m/manager/you) is valid
if printf '%s' "$low" | grep -Eq '(^| )(he|she|they) (can|may|could)'; then exit 1; fi

# --- affirmative grant trigger ----------------------------------------------
# must grant MERGE to M/manager/you, affirmatively
if ! printf '%s' "$low" | grep -Eq '(m|manager|you) (can|may|is|are|should) (now )?(merge|do the merge|be allowed to merge|authoriz)'; then
  if ! printf '%s' "$low" | grep -Eq 'merge authority|authoriz.* to merge|grant.* merge|let (m|manager) merge|(m|manager) merge(s|) (the )?(pr|prs)'; then
    exit 1
  fi
fi

# --- candidate scope extraction (guarded against incidental text) -----------
scope="unscoped"
if printf '%s' "$low" | grep -Eq 'this sprint|this-sprint|the sprint|sprint-scoped|whole sprint|all sprint'; then
  scope="this-sprint"
elif printf '%s' "$low" | grep -Eq 'per[ -]item|each (pr|item)|item by item|one pr at a time'; then
  scope="per-item"
elif printf '%s' "$low" | grep -Eq 'final (pr|merge|integration)|integration(.{0,8})(to )?main|merge.*to main|the final pr'; then
  # guard: "integration tests" / "final approval" are NOT a merge scope
  if ! printf '%s' "$low" | grep -Eq 'integration test|final approval|final review'; then
    scope="final-integration"
  fi
fi

printf '{"candidate":true,"scope":"%s","raw":%s}\n' "$scope" "$(printf '%s' "$phrase" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
exit 0
