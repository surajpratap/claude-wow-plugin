#!/usr/bin/env bash
# wow-config.sh — read/write the consolidated project-mode state at
# ${WOW_ROOT}/implementations/config.json.
#
# Usage:
#   wow-config.sh get <jq-path>             # print the value at the path
#   wow-config.sh set <jq-path> <json>      # atomic read-modify-write
#   wow-config.sh del <jq-path>             # remove the key at the path
#
# Semantics:
#   - Missing file == {"schema":1,"mode":"default"}. `get` never errors on a
#     fresh project; `set` creates the file (defaults merged) first.
#   - <jq-path> is a dotted path (.mode, .ahod.assignments.tester); segments
#     are [A-Za-z0-9_-] only — anything else exits 2 (no jq-program injection).
#   - <json> must be a valid JSON value ('"ahod"', '{"a":1}', 'null').
#   - .mode is a closed enum: "default" | "ahod".
#   - Writes are atomic (temp file + mv). M is the only writer by doctrine.
set -u

# Worktree-invariant ROOT: $WOW_ROOT override first, else the
# --git-common-dir parent — never --show-toplevel (the worktree root).
if [ -z "${WOW_ROOT:-}" ]; then
  WOW_ROOT=$(pwd)
  if _gcd=$(git rev-parse --git-common-dir 2>/dev/null); then
    case "$_gcd" in /*) ;; *) _gcd="$(pwd)/$_gcd" ;; esac
    WOW_ROOT=$(cd "$(dirname "$_gcd")" 2>/dev/null && pwd) || WOW_ROOT=$(pwd)
  fi
  unset _gcd
fi

CONFIG="${WOW_ROOT}/implementations/config.json"
DEFAULTS='{"schema":1,"mode":"default"}'

usage() {
  echo "usage: wow-config.sh get <jq-path> | set <jq-path> <json-value> | del <jq-path>" >&2
}

valid_path() {
  printf '%s' "$1" | grep -qE '^\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$'
}

current() {
  if [ -f "$CONFIG" ]; then
    jq --argjson d "$DEFAULTS" '$d * .' "$CONFIG" 2>/dev/null || printf '%s' "$DEFAULTS"
  else
    printf '%s' "$DEFAULTS"
  fi
}

CMD="${1:-}"
PATH_ARG="${2:-}"

case "$CMD" in
  get)
    { [ -n "$PATH_ARG" ] && valid_path "$PATH_ARG"; } || { usage; exit 2; }
    current | jq -r --arg p "${PATH_ARG#.}" 'getpath($p / ".") // empty'
    ;;
  set)
    VALUE="${3:-}"
    { [ -n "$PATH_ARG" ] && valid_path "$PATH_ARG" && [ -n "$VALUE" ]; } || { usage; exit 2; }
    if ! printf '%s' "$VALUE" | jq -e . >/dev/null 2>&1; then
      echo "wow-config.sh: value is not valid JSON: $VALUE" >&2
      exit 2
    fi
    if [ "$PATH_ARG" = ".mode" ]; then
      case "$VALUE" in
        '"default"'|'"ahod"') ;;
        *) echo "wow-config.sh: .mode must be \"default\" or \"ahod\" (got: $VALUE)" >&2; exit 2 ;;
      esac
    fi
    mkdir -p "$(dirname "$CONFIG")"
    TMP="${CONFIG}.tmp.$$"
    if current | jq --arg p "${PATH_ARG#.}" --argjson v "$VALUE" 'setpath($p / "."; $v)' > "$TMP"; then
      mv -f "$TMP" "$CONFIG"
    else
      rm -f "$TMP"
      echo "wow-config.sh: set failed" >&2
      exit 1
    fi
    ;;
  del)
    { [ -n "$PATH_ARG" ] && valid_path "$PATH_ARG"; } || { usage; exit 2; }
    [ -f "$CONFIG" ] || exit 0
    TMP="${CONFIG}.tmp.$$"
    if jq --arg p "${PATH_ARG#.}" 'delpaths([$p / "."])' "$CONFIG" > "$TMP"; then
      mv -f "$TMP" "$CONFIG"
    else
      rm -f "$TMP"
      echo "wow-config.sh: del failed" >&2
      exit 1
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
