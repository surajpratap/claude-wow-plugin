#!/usr/bin/env bash
# Story 020 — gh-webhook forwarder pre-spawn cleanup regression test.
#
# Synthetic-fixture bash test exercising bridge/github/run.py's
# _cleanup_stale_webhook helper + spawn-time cleanup-then-spawn order.
# Uses a fake `gh` shim on PATH that records argv to a log file and
# returns canned responses driven by env vars.
#
# Asserts:
# 1. _cleanup_stale_webhook lists hooks via `gh api repos/<repo>/hooks`.
# 2. When the list contains a stale "cli"-named webhook with the
#    forwarder URL, the helper deletes it via `gh api repos/<repo>/hooks/<id> -X DELETE`.
# 3. When the list contains NO matching hook, no DELETE call is made.
# 4. When the list contains a "cli"-named hook but with a DIFFERENT url
#    (user-created), the helper does NOT delete (two-property match
#    prevents false positives).
# 5. Regression guard: the spawn argv is unchanged shape
#    (--repo, --events, --url) — the fix didn't touch the spawn args.

set -u

PASS=0
FAIL=0
FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (expected '$expected', got '$actual')")
  fi
}

assert_match() {
  local name="$1"; local pattern="$2"; local actual="$3"
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name (pattern '$pattern' not found in '$actual')")
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_PY="$REPO_ROOT/bridge/github/run.py"
[ -f "$RUN_PY" ] || { echo "ERROR: $RUN_PY not found" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Fake gh shim (per case) — records argv, returns canned response.
# -----------------------------------------------------------------------------
make_shim() {
  local dir="$1"
  local list_response="$2"  # path to JSON file with hooks list
  cat > "$dir/gh" <<SHIM
#!/usr/bin/env bash
LOG="$dir/gh-calls.log"
printf '%s\n' "\$*" >> "\$LOG"
case "\$1" in
  api)
    case "\$2" in
      */hooks)
        # GET hooks list — return canned response
        cat "$list_response"
        ;;
      */hooks/*)
        # DELETE hook (token "-X" "DELETE" follows path)
        # Just succeed; nothing to print
        :
        ;;
      *)
        echo '{}'
        ;;
    esac
    ;;
  *)
    echo "unhandled gh subcmd: \$1" >&2
    exit 1
    ;;
esac
exit 0
SHIM
  chmod +x "$dir/gh"
}

# Run the helper via Python with PATH overridden to point at our shim.
run_cleanup() {
  local dir="$1"; local repo="${2:-test-org/test-repo}"
  PATH="$dir:$PATH" python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/bridge/github')
import run
run._cleanup_stale_webhook('test-bridge-id', '$repo')
" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------

# Case 1: stale "cli" webhook with forwarder URL → list + delete called.
DIR=$(mktemp -d)
cat > "$DIR/hooks.json" <<'JSON'
[{"id":12345,"name":"cli","config":{"url":"https://webhook-forwarder.github.com/hook","content_type":"json"}}]
JSON
make_shim "$DIR" "$DIR/hooks.json"
run_cleanup "$DIR" "myorg/myrepo"
LOG="$DIR/gh-calls.log"
LIST_CALL=$(grep -E '^api repos/myorg/myrepo/hooks$' "$LOG" | head -1)
DELETE_CALL=$(grep -E '^api repos/myorg/myrepo/hooks/12345 -X DELETE$' "$LOG" | head -1)
assert_match "case-1-list-call" 'api repos/myorg/myrepo/hooks' "$LIST_CALL"
assert_match "case-1-delete-call" 'api repos/myorg/myrepo/hooks/12345 -X DELETE' "$DELETE_CALL"
# Verify ordering — list precedes delete in the log.
ORDER=$(awk '/api repos.*hooks$/ {l=NR} /api repos.*hooks\/12345 -X DELETE$/ {d=NR} END {print (l<d)?"ok":"bad"}' "$LOG")
assert_eq "case-1-list-precedes-delete" "ok" "$ORDER"
rm -rf "$DIR"

# Case 2: no matching hook → list called, no delete.
DIR=$(mktemp -d)
echo '[]' > "$DIR/hooks.json"
make_shim "$DIR" "$DIR/hooks.json"
run_cleanup "$DIR" "myorg/myrepo"
LIST_COUNT=$(grep -cE '^api repos/myorg/myrepo/hooks$' "$DIR/gh-calls.log")
DELETE_COUNT=$(grep -cE '^api repos.*hooks/[0-9]+ -X DELETE$' "$DIR/gh-calls.log"; true)
assert_eq "case-2-list-called-once" "1" "$LIST_COUNT"
assert_eq "case-2-no-delete-call" "0" "$DELETE_COUNT"
rm -rf "$DIR"

# Case 3: "cli"-named hook but DIFFERENT url (user-created) → no delete.
# Two-property match prevents false-positive deletion.
DIR=$(mktemp -d)
cat > "$DIR/hooks.json" <<'JSON'
[{"id":99999,"name":"cli","config":{"url":"https://example.com/my-custom-hook","content_type":"json"}}]
JSON
make_shim "$DIR" "$DIR/hooks.json"
run_cleanup "$DIR" "myorg/myrepo"
DELETE_COUNT=$(grep -cE '^api repos.*hooks/[0-9]+ -X DELETE$' "$DIR/gh-calls.log"; true)
assert_eq "case-3-user-cli-hook-not-deleted" "0" "$DELETE_COUNT"
rm -rf "$DIR"

# Case 4: hook with forwarder URL but DIFFERENT name → no delete.
# Two-property match prevents false-positive deletion (defensive).
DIR=$(mktemp -d)
cat > "$DIR/hooks.json" <<'JSON'
[{"id":77777,"name":"web","config":{"url":"https://webhook-forwarder.github.com/hook","content_type":"json"}}]
JSON
make_shim "$DIR" "$DIR/hooks.json"
run_cleanup "$DIR" "myorg/myrepo"
DELETE_COUNT=$(grep -cE '^api repos.*hooks/[0-9]+ -X DELETE$' "$DIR/gh-calls.log"; true)
assert_eq "case-4-non-cli-name-not-deleted" "0" "$DELETE_COUNT"
rm -rf "$DIR"

# Case 5: multiple hooks, one matches → only the matching one is deleted.
DIR=$(mktemp -d)
cat > "$DIR/hooks.json" <<'JSON'
[
  {"id":11111,"name":"web","config":{"url":"https://example.com/a","content_type":"json"}},
  {"id":22222,"name":"cli","config":{"url":"https://webhook-forwarder.github.com/hook","content_type":"json"}},
  {"id":33333,"name":"cli","config":{"url":"https://example.org/different","content_type":"json"}}
]
JSON
make_shim "$DIR" "$DIR/hooks.json"
run_cleanup "$DIR" "myorg/myrepo"
DEL_22222=$(grep -cE '^api repos.*hooks/22222 -X DELETE$' "$DIR/gh-calls.log"; true)
DEL_11111=$(grep -cE '^api repos.*hooks/11111 -X DELETE$' "$DIR/gh-calls.log"; true)
DEL_33333=$(grep -cE '^api repos.*hooks/33333 -X DELETE$' "$DIR/gh-calls.log"; true)
assert_eq "case-5-match-22222-deleted" "1" "$DEL_22222"
assert_eq "case-5-non-match-11111-skipped" "0" "$DEL_11111"
assert_eq "case-5-non-match-33333-skipped" "0" "$DEL_33333"
rm -rf "$DIR"

# Case 6: regression guard for the spawn argv shape (no spawn invocation;
# we just inspect the source file to ensure the args remain).
SPAWN_LINE=$(grep -E '"gh", "webhook", "forward"' "$RUN_PY" | head -1)
assert_match "case-6-spawn-keeps-gh-webhook-forward" '"gh", "webhook", "forward"' "$SPAWN_LINE"
REPO_ARG=$(grep -E '"--repo", repo' "$RUN_PY" | head -1)
assert_match "case-6-spawn-keeps-repo-arg" '"--repo", repo' "$REPO_ARG"
EVENTS_ARG=$(grep -E '"--events", WEBHOOK_EVENTS' "$RUN_PY" | head -1)
assert_match "case-6-spawn-keeps-events-arg" '"--events", WEBHOOK_EVENTS' "$EVENTS_ARG"
URL_ARG=$(grep -E '"--url", f"http://localhost:\{port\}/webhook"' "$RUN_PY" | head -1)
assert_match "case-6-spawn-keeps-url-arg" '"--url", f"http://localhost:.port./webhook"' "$URL_ARG"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
echo "github-bridge-forwarder-args: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
