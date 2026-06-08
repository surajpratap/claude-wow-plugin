#!/usr/bin/env bash
# accuracy-trace-lint.sh — lint a plan's `## Accuracy-trace map` against the
# story's `<!-- accuracy-trace: required -->` marker. Modeled on
# plan-shape-check.sh: per-file, draft-exempt (line 1 == the drafting marker),
# collects ALL offenders (no set -e), prefixed output.
#
# Usage: accuracy-trace-lint.sh <plan-file> [<plan-file>...]
#
# Derives the story path from the plan's `Story:` line. If the story carries
# `<!-- accuracy-trace: required -->`, a valid `## Accuracy-trace map` table is
# REQUIRED; ERRORs (exit 1):
#   (a) map section absent
#   (b) an `Authoritative source` basename in {AGENTS.md,CLAUDE.md,README.md}
#   (c) a row missing a `Verifier` in {pp,t}
#   (d) a quoted `Anchor` that does not grep-match the cited source file
# WARN (never fails): doc-heavy text but unmarked; or >=3 rows all one verifier.
#
# Exit: 0 = clean (WARNs allowed), 1 = >=1 ERROR or unreadable, 2 = usage.

set -u

if [ "$#" -lt 1 ]; then
  echo "usage: accuracy-trace-lint.sh <plan-file> [<plan-file>...]" >&2
  exit 2
fi

DOC_HEAVY_RE='readme|docs/|accurate to|feature.{0,4}(claim|description)|describes (the|how)|customer-facing'

rc=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "ACCURACY-TRACE: file not found — $f" >&2
    rc=1
    continue
  fi

  line1=$(head -1 "$f" | tr -d '\r')
  [ "$line1" = "<!-- status: drafting -->" ] && continue   # draft-exempt

  # Repo root from the plan path: <root>/implementations/plans/<file>.
  root=$(cd "$(dirname "$f")/../.." 2>/dev/null && pwd)
  [ -z "$root" ] && root="."

  # Story path from the `Story:` line (repo-relative).
  story_rel=$(grep -E '^Story:' "$f" | head -1 | sed -E 's/^Story:[[:space:]]*//; s/[[:space:]]+$//')
  story="$root/$story_rel"

  # Marker must be a STANDALONE frontmatter line (column 0), not an inline prose
  # mention — else a story that DESCRIBES the convention (e.g. backtick-wrapped
  # `<!-- accuracy-trace: required -->` in its AC text) would self-trigger.
  marked=0
  if [ -n "$story_rel" ] && [ -f "$story" ] \
     && grep -qE '^<!-- accuracy-trace: required -->[[:space:]]*$' "$story" 2>/dev/null; then
    marked=1
  fi

  # Does the plan have a map section?
  has_map=0
  grep -Eq '^## Accuracy-trace map[[:space:]]*$' "$f" && has_map=1

  if [ "$marked" -eq 0 ]; then
    # Heuristic backstop: doc-heavy but unmarked -> WARN (never fails).
    if [ "$has_map" -eq 0 ] && grep -Eiq "$DOC_HEAVY_RE" "$f" 2>/dev/null; then
      echo "ACCURACY-TRACE: WARN — $f looks doc/claim-heavy but its story has no <!-- accuracy-trace: required --> marker (add the marker + a map, or ignore if not claim-heavy)" >&2
    fi
    continue
  fi

  # Marked => a valid map is required.
  if [ "$has_map" -eq 0 ]; then
    echo "ACCURACY-TRACE: ERROR — story marked accuracy-trace:required but plan has no '## Accuracy-trace map' section — $f" >&2
    rc=1
    continue
  fi

  # Extract data rows under the map heading (until the next `## ` or EOF).
  rows=$(awk '/^## Accuracy-trace map[[:space:]]*$/{f=1;next} /^## /{f=0} f' "$f" | grep -E '^\|')
  pp_count=0; t_count=0; row_count=0; seen=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    body="${row#|}"; body="${body%|}"
    # Separator row -> skip. Delete the LITERAL set {space,:,|,-}: hyphen LAST so tr
    # reads it as a literal, NOT the 0x3A-0x7C range ':-|' would denote (BSD trap).
    if [ -z "$(printf '%s' "$body" | tr -d ' :|-')" ]; then continue; fi
    IFS='|' read -ra cells <<<"$body"
    c0=$(printf '%s' "${cells[0]:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z')
    # Header row -> skip (checked before the column count so the 4-col header is
    # never mistaken for a claim row).
    [ "$c0" = "claim" ] && continue
    seen=$((seen+1))   # a data-shaped row (valid OR malformed); drives the empty-map check
    if [ "${#cells[@]}" -ne 4 ]; then
      echo "ACCURACY-TRACE: ERROR — malformed map row (need 4 columns: Claim | Authoritative source | Anchor | Verifier) — $f" >&2
      rc=1; continue
    fi
    claim=$(printf '%s' "${cells[0]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    src=$(printf  '%s' "${cells[1]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    anchor=$(printf '%s' "${cells[2]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    verifier=$(printf '%s' "${cells[3]}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z')
    row_count=$((row_count+1))

    # (b) banned summary-doc citation.
    case "$(basename "$src")" in
      AGENTS.md|CLAUDE.md|README.md)
        echo "ACCURACY-TRACE: ERROR — row '$claim' cites a summary doc ($src); cite the authoritative role file / protocol spec / script — $f" >&2
        rc=1 ;;
    esac

    # (c) verifier must be pp|t.
    case "$verifier" in
      pp) pp_count=$((pp_count+1)) ;;
      t)  t_count=$((t_count+1)) ;;
      *)  echo "ACCURACY-TRACE: ERROR — row '$claim' has no Verifier in {pp,t} (got '$verifier') — $f" >&2; rc=1 ;;
    esac

    # (d) anchor must grep-match the cited source.
    anchor_text=$(printf '%s' "$anchor" | sed -E 's/^"(.*)"$/\1/')
    src_abs="$root/$src"
    if [ -z "$anchor_text" ]; then
      echo "ACCURACY-TRACE: ERROR — row '$claim' has an empty Anchor (need a grep-able quoted substring) — $f" >&2; rc=1
    elif [ ! -f "$src_abs" ]; then
      echo "ACCURACY-TRACE: ERROR — row '$claim' cites a source that does not exist ($src) — $f" >&2; rc=1
    elif ! grep -Fq "$anchor_text" "$src_abs" 2>/dev/null; then
      echo "ACCURACY-TRACE: ERROR — row '$claim' anchor not found in $src: \"$anchor_text\" — $f" >&2; rc=1
    fi
  done <<EOF
$rows
EOF

  # (a, cont.) marked story + map heading present but ZERO claim rows -> ERROR
  # (an empty or all-malformed map is not a valid trace).
  if [ "$seen" -eq 0 ]; then
    echo "ACCURACY-TRACE: ERROR — '## Accuracy-trace map' present but has no claim rows — $f" >&2
    rc=1
  fi

  # (e) WARN: >=3 rows all one verifier (no real split).
  if [ "$row_count" -ge 3 ] && { [ "$pp_count" -eq 0 ] || [ "$t_count" -eq 0 ]; }; then
    echo "ACCURACY-TRACE: WARN — $row_count claims all assigned to one verifier (pp=$pp_count t=$t_count); split the claim surface — $f" >&2
  fi
done

exit "$rc"
