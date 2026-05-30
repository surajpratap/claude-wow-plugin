#!/usr/bin/env bash
# external-review.sh — wrap an external reviewer (configurable via
# WOW_REVIEW_CMD; default `codex`) with the load-bearing `< /dev/null`
# stdin redirect baked in. Prevents the silent-hang failure
# mode an external reviewer process hits when launched in the background
# without an EOF on stdin.
#
# Usage: external-review.sh -o <output-file> (--prompt-file <path> | <prompt>)
#
# --prompt-file is the footgun-free route: the prompt travels as file CONTENT,
# so a backtick / $(...) in it is never command-substituted by the caller's
# shell. The positional <prompt> form is retained for backward-compat.
#
# Env vars (consuming-project config):
#   WOW_REVIEW_CMD    Reviewer command (default: codex).
#   WOW_REVIEW_FLAGS  Reviewer flags    (default: --dangerously-bypass-approvals-and-sandbox).

set -u

OUT=""; PROMPT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

# Resolve the prompt body. With --prompt-file, PROMPT="$(cat ...)" captures the
# file BYTES as a variable value — a value is NOT re-evaluated for command
# substitution when later passed as "$PROMPT" argv, so backticks / $(...) in the
# content stay inert end-to-end. Positional <prompt> retained for backward-compat.
if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || { echo "external-review.sh: --prompt-file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
elif [ $# -ge 1 ]; then
  PROMPT="$1"
else
  PROMPT=""
fi

if [ -z "$OUT" ] || [ -z "$PROMPT" ]; then
  echo "usage: external-review.sh -o <output-file> (--prompt-file <path> | <prompt>)" >&2
  exit 2
fi

REVIEW_CMD="${WOW_REVIEW_CMD:-codex}"
REVIEW_FLAGS="${WOW_REVIEW_FLAGS:---dangerously-bypass-approvals-and-sandbox}"

# Intentionally word-split $REVIEW_FLAGS so an operator-set flag string
# like "--foo --bar" passes as two args. The `< /dev/null` is load-bearing.
# shellcheck disable=SC2086
exec "$REVIEW_CMD" exec $REVIEW_FLAGS -o "$OUT" "$PROMPT" < /dev/null
