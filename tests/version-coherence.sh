#!/usr/bin/env bash
# Compare the plugin-version literal in commands/_manager-startup.md to the
# version field in .claude-plugin/plugin.json. They must match.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STARTUP_MD="$REPO_ROOT/commands/_manager-startup.md"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$STARTUP_MD" ]; then
  echo "ERROR: $STARTUP_MD not found" >&2
  exit 2
fi
if [ ! -f "$PLUGIN_JSON" ]; then
  echo "ERROR: $PLUGIN_JSON not found" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required" >&2
  exit 2
fi

# Match the line: M targets plugin version **`X.Y.Z`**.
MD_VERSION=$(grep -oE 'plugin version \*\*`[0-9]+\.[0-9]+\.[0-9]+`' "$STARTUP_MD" \
  | head -1 \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

JSON_VERSION=$(jq -r '.version' "$PLUGIN_JSON")

if [ -z "$MD_VERSION" ]; then
  echo "ERROR: could not extract plugin-version literal from $STARTUP_MD"
  echo "  expected a line containing: plugin version **\`X.Y.Z\`**"
  exit 1
fi
if [ -z "$JSON_VERSION" ] || [ "$JSON_VERSION" = "null" ]; then
  echo "ERROR: could not read .version from $PLUGIN_JSON"
  exit 1
fi

if [ "$MD_VERSION" != "$JSON_VERSION" ]; then
  echo "ERROR: version mismatch"
  echo "  commands/_manager-startup.md : $MD_VERSION"
  echo "  .claude-plugin/plugin.json   : $JSON_VERSION"
  echo "Bump both together when releasing a new plugin version."
  exit 1
fi

echo "OK — both report version $MD_VERSION"
exit 0
