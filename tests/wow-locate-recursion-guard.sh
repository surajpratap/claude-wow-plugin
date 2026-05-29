#!/usr/bin/env bash
# Bug 0002, Layer C — wow-locate PATH-shadow recursion guard.
# When wow-locate is hardlinked (or otherwise inode-identical) at two
# PATH entries, the script must exit 3 with a "PATH-shadow recursion
# detected" stderr message.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name (expected '$expected', got '$actual')"); fi
}
assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  case "$hay" in
    *"$needle"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); FAILED_CASES+=("$name (haystack missing '$needle')") ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WOW_LOCATE="$ROOT/bin/wow-locate"

[ -x "$WOW_LOCATE" ] || { echo "wow-locate not executable at $WOW_LOCATE"; exit 1; }

# Case 1: normal invocation works (resolves a known plugin file)
OUT=$("$WOW_LOCATE" commands/_agent-protocol.md 2>&1)
RC=$?
assert_eq "case1: normal invocation exit 0" "0" "$RC"
assert_contains "case1: returned a path" "/commands/_agent-protocol.md" "$OUT"

# Case 2: hardlink → PATH-shadow recursion → exit 3
TMP1=$(mktemp -d)
TMP2=$(mktemp -d)
ln "$WOW_LOCATE" "$TMP1/wow-locate"
ln "$WOW_LOCATE" "$TMP2/wow-locate"

ERR=$(PATH="$TMP1:$TMP2:$PATH" "$TMP1/wow-locate" commands/_agent-protocol.md 2>&1 >/dev/null)
RC=$(PATH="$TMP1:$TMP2:$PATH" "$TMP1/wow-locate" commands/_agent-protocol.md >/dev/null 2>&1; echo $?)

assert_eq "case2: shadow-recursion exit 3" "3" "$RC"
assert_contains "case2: error mentions PATH-shadow recursion" "PATH-shadow recursion detected" "$ERR"
assert_contains "case2: error mentions fork-bomb class" "fork-bomb class" "$ERR"

rm -rf "$TMP1" "$TMP2"

# Case 3: legit shim (different inode, different file) does NOT trigger the guard
TMP3=$(mktemp -d)
cat > "$TMP3/wow-locate" <<'EOF'
#!/usr/bin/env bash
# legit shim: pretends to be wow-locate; not the same file
echo "shim-passthrough"
exit 0
EOF
chmod +x "$TMP3/wow-locate"
# Run the real wow-locate (NOT the shim); shim is later on PATH (different inode).
OUT=$(PATH="$ROOT/bin:$TMP3:$PATH" "$WOW_LOCATE" commands/_agent-protocol.md 2>&1)
RC=$?
assert_eq "case3: legit different-file shim doesn't trigger guard" "0" "$RC"
rm -rf "$TMP3"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
