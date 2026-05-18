#!/usr/bin/env bash
# external-review.sh — wrap an external reviewer (configurable via
# WOW_REVIEW_CMD; default `codex`) with the load-bearing `< /dev/null`
# stdin redirect baked in (Story 112). Prevents the silent-hang failure
# mode an external reviewer process hits when launched in the background
# without an EOF on stdin.
#
# Usage: external-review.sh -o <output-file> <prompt>
#
# Env vars (consuming-project config):
#   WOW_REVIEW_CMD    Reviewer command (default: codex).
#   WOW_REVIEW_FLAGS  Reviewer flags    (default: --dangerously-bypass-approvals-and-sandbox).

set -u

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ -z "$OUT" ] || [ $# -lt 1 ]; then
  echo "usage: external-review.sh -o <output-file> <prompt>" >&2
  exit 2
fi

REVIEW_CMD="${WOW_REVIEW_CMD:-codex}"
REVIEW_FLAGS="${WOW_REVIEW_FLAGS:---dangerously-bypass-approvals-and-sandbox}"

# Intentionally word-split $REVIEW_FLAGS so an operator-set flag string
# like "--foo --bar" passes as two args. The `< /dev/null` is load-bearing.
# shellcheck disable=SC2086
exec "$REVIEW_CMD" exec $REVIEW_FLAGS -o "$OUT" "$1" < /dev/null
