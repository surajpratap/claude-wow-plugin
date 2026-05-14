#!/usr/bin/env bash
# Cross-reference integrity check for commands/*.md.
#
# Strategy: extract candidate path-shaped strings from each markdown file
# (markdown link targets and inline-backtick strings containing a /), then
# classify each candidate as one of:
#   real  — checkable repo-relative path → file must exist
#   warn  — looks like a path but is not a clean repo-relative reference
#          (template substitution, regex, runtime artifact, etc.) → don't fail
#   skip  — definitely not a checkable path (URL, anchor, empty)
#
# We deliberately accept that the WARN bucket is noisy. The test's job is to
# catch true broken references (typos, renamed files), not to lint every
# path-like phrase in the prose. Better noisy-WARN than silent-FALSE-NEGATIVE.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
COMMANDS_DIR="$REPO_ROOT/commands"

if [ ! -d "$COMMANDS_DIR" ]; then
  echo "ERROR: $COMMANDS_DIR not found" >&2
  exit 2
fi

# Top-level dirs whose contents are committed. Paths starting with these
# prefixes are checkable for existence. Anything else is treated as a warn
# (could be runtime, could be an example, could be a hostname, could be a
# regex fragment — none are our problem to validate).
CHECKABLE_PREFIXES=(
  "commands/"
  "scripts/"
  "docs/"
  "tools/"
  "tests/"
  ".claude-plugin/"
  "bridge/"
)

ERRORS=0
WARNS=0

clean_path() {
  local p="$1"
  p="${p%%#*}"      # strip #anchor
  p="${p%%\?*}"     # strip ?query
  # Trim whitespace.
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  echo "$p"
}

classify() {
  local p="$1"

  # URLs, anchors, mailto, empty.
  case "$p" in
    http://*|https://*|ftp://*|mailto:*|\#*|"") echo skip; return ;;
  esac

  # Home-dir refs (`~/.aws/...`), absolute paths (`/Users/...`), template
  # substitutions (`${ROOT}/...`, `<NNN-slug>`), regex artifacts (`\.foo`),
  # globs, multi-word strings — all warn-only.
  case "$p" in
    \~*|/*) echo warn; return ;;
    *\$*|*\<*|*\>*|*\\*) echo warn; return ;;
    *\**|*\?*|*\{*|*\[*) echo warn; return ;;
    *' '*) echo warn; return ;;
  esac

  # Must contain a /.
  case "$p" in
    */*) ;;
    *) echo skip; return ;;
  esac

  # Strip leading ./
  case "$p" in
    ./*) p="${p#./}" ;;
  esac

  # Only check paths under known committed top-level dirs.
  for prefix in "${CHECKABLE_PREFIXES[@]}"; do
    case "$p" in
      "$prefix"*)
        # Don't check if it ends with / and is a directory-glob phrase.
        case "$p" in
          *_*\.\.\.*|*…*) echo warn; return ;;
        esac
        echo "real:$p"
        return
        ;;
    esac
  done

  # Anything else — runtime path (implementations/...), hostname (foo/bar),
  # regex (a/b/c with special chars we missed), narrative phrase ("path/to").
  echo warn
}

shopt -s nullglob 2>/dev/null || true
for md in "$COMMANDS_DIR"/*.md; do
  rel="${md#$REPO_ROOT/}"

  link_targets=$(grep -oE '\[[^]]+\]\([^)]+\)' "$md" \
    | sed -E 's/^\[[^]]+\]\(([^)]+)\)/\1/')
  inline_paths=$(grep -oE '`[^`]+`' "$md" \
    | sed -E 's/^`(.+)`$/\1/' \
    | grep -E '/' || true)

  candidates=$(printf '%s\n%s\n' "$link_targets" "$inline_paths" | sort -u)

  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    cleaned=$(clean_path "$raw")
    cls=$(classify "$cleaned")

    case "$cls" in
      skip) ;;
      warn)
        echo "WARN [$rel]: $raw"
        WARNS=$((WARNS+1))
        ;;
      real:*)
        path="${cls#real:}"
        if [ ! -e "$REPO_ROOT/$path" ] && [ ! -e "$SOURCE_ROOT/$path" ]; then
          echo "ERROR [$rel]: missing path: $path"
          ERRORS=$((ERRORS+1))
        fi
        ;;
    esac
  done <<< "$candidates"
done

echo
echo "$ERRORS ERROR(s), $WARNS WARN(s)"
[ "$ERRORS" -ne 0 ] && exit 1
exit 0
