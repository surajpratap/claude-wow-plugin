#!/usr/bin/env bash
# Bug 0009 (MEDIUM) — BEHAVIORAL test for the Bug 0009 build-gate
# fix in `_slacker-startup.md` (actually commands/slacker.md step 4b).
#
# Pre-Story-163 the gate ran `npm run build` only when `[ ! -d dist ] ||
# [ LOCK_SHA != SAVED_SHA ]`. Story 157 shipped with the SHAs matching
# but `src/` edited; the gate skipped, a stale `dist/index.js` (without
# Attachments wiring) ran the bridge silently. The fix adds a third
# clause: any file under `src/` newer than `dist/` triggers a rebuild.
#
# This test creates a fixture with dist older than src, runs the
# extracted gate snippet against a fake `npm` shim, and asserts the
# build was triggered.

set -u
PASS=0; FAIL=0; FAILED_CASES=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR_FX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FX"' EXIT INT TERM

mkdir -p "$TMPDIR_FX/bridge/src" "$TMPDIR_FX/bridge/dist" "$TMPDIR_FX/bin"
echo "console.log('stale');" > "$TMPDIR_FX/bridge/dist/index.js"
touch -t 202401010000 "$TMPDIR_FX/bridge/dist"
touch -t 202401010000 "$TMPDIR_FX/bridge/dist/index.js"
# Sleep + touch src LAST so its mtime is newer than dist.
sleep 1
echo "export const handler = () => 1;" > "$TMPDIR_FX/bridge/src/handlers.ts"

# Lock SHA matches saved SHA — without the Bug 0009 fix, this would
# skip the build.
echo "AAAA" > "$TMPDIR_FX/bridge/package-lock.json"
echo "$(shasum -a 1 "$TMPDIR_FX/bridge/package-lock.json" | awk '{print $1}')" \
  > "$TMPDIR_FX/bridge/.deps-installed"

# Fake `npm` shim records that build was invoked.
cat > "$TMPDIR_FX/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ "$2" = "build" ]; then
  echo "BUILD_FIRED" > "$NPM_SHIM_MARKER"
fi
exit 0
EOF
chmod +x "$TMPDIR_FX/bin/npm"

# Extract the gate snippet from slacker.md step 4b and run it. The
# imperative shape is exact; if a future doctrine edit reorders or
# weakens it, the test fails until reworded.
run_gate() {
  local marker_file="$1"
  NPM_SHIM_MARKER="$marker_file" \
  PATH="$TMPDIR_FX/bin:$PATH" \
  SLACK_BRIDGE_DIR="$TMPDIR_FX/bridge" \
  bash -c '
    LOCK_SHA=$(shasum -a 1 "$SLACK_BRIDGE_DIR/package-lock.json" | awk "{print \$1}")
    SAVED_SHA=$(cat "$SLACK_BRIDGE_DIR/.deps-installed" 2>/dev/null || true)
    STALE_DIST=""
    if [ -d "$SLACK_BRIDGE_DIR/dist" ] && [ -d "$SLACK_BRIDGE_DIR/src" ]; then
      STALE_DIST=$(find "$SLACK_BRIDGE_DIR/src" -newer "$SLACK_BRIDGE_DIR/dist" -print -quit 2>/dev/null)
    fi
    if [ ! -d "$SLACK_BRIDGE_DIR/dist" ] || [ "$LOCK_SHA" != "$SAVED_SHA" ] || [ -n "$STALE_DIST" ]; then
      npm run build
    fi
  '
}

# ---- Case 1: stale dist (src newer than dist), SHAs match → rebuild fires ----
MARK1="$TMPDIR_FX/mark1"
rm -f "$MARK1"
run_gate "$MARK1"
if [ -f "$MARK1" ] && [ "$(cat "$MARK1")" = "BUILD_FIRED" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("1-stale-dist-rebuild (npm run build NOT triggered when src newer than dist)")
fi

# ---- Case 2: clean state (dist newer than src), SHAs match → no rebuild ----
# Touch dist newer than src by recreating it.
touch -t 202712310000 "$TMPDIR_FX/bridge/dist"
MARK2="$TMPDIR_FX/mark2"
rm -f "$MARK2"
run_gate "$MARK2"
if [ ! -f "$MARK2" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("2-clean-dist-skip (npm run build triggered when dist newer than src)")
fi

# ---- Case 3: doctrine has the Bug 0009 imperative shape ----
DOC="$ROOT/commands/slacker.md"
if grep -qF '-newer "$SLACK_BRIDGE_DIR/dist"' "$DOC"; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("3-doctrine-newer-clause (slacker.md missing the find -newer clause)")
fi

echo "slacker-startup-rebuilds-on-stale-dist: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
