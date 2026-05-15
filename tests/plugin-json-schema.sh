#!/usr/bin/env bash
# Verify .claude-plugin/plugin.json and .claude-plugin/marketplace.json are
# valid JSON with the required top-level fields.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required" >&2
  exit 2
fi

ERRORS=0

check_parses() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "ERROR: $file not found"
    ERRORS=$((ERRORS+1))
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "ERROR: $file does not parse as valid JSON"
    ERRORS=$((ERRORS+1))
    return 1
  fi
  return 0
}

check_field() {
  local file="$1"
  local query="$2"
  local desc="$3"
  if ! jq -e "$query" "$file" >/dev/null 2>&1; then
    echo "ERROR: $file missing $desc (jq: $query)"
    ERRORS=$((ERRORS+1))
  fi
}

# plugin.json
if check_parses "$PLUGIN_JSON"; then
  check_field "$PLUGIN_JSON" 'has("name")'        'top-level "name"'
  check_field "$PLUGIN_JSON" 'has("version")'     'top-level "version"'
  check_field "$PLUGIN_JSON" 'has("description")' 'top-level "description"'

  # Plugin dependencies (Story 078). Schema per Claude Code docs:
  # https://code.claude.com/docs/en/plugin-dependencies
  # `dependencies` is an array; object-form entries are {name, version?, marketplace?}.
  # `version` is OPTIONAL — playwright's plugin.json exposes no version field, so its
  # dependency entry deliberately omits the key. Count check is `>= 2` (not `== 2`) so a
  # future 3rd dependency does not break this test; per-entry asserts cover presence.
  check_field "$PLUGIN_JSON" '.dependencies | type == "array"' '.dependencies to be an array'
  check_field "$PLUGIN_JSON" '.dependencies | length >= 2'     '.dependencies to have at least 2 entries'
  check_field "$PLUGIN_JSON" \
    '.dependencies | map(select(.name=="superpowers")) | .[0] | has("name") and has("version") and has("marketplace")' \
    'superpowers dependency entry with name+version+marketplace'
  check_field "$PLUGIN_JSON" \
    '.dependencies | map(select(.name=="playwright")) | .[0] | has("name") and has("marketplace") and (has("version")|not)' \
    'playwright dependency entry with name+marketplace and no version'
fi

# marketplace.json
if check_parses "$MARKETPLACE_JSON"; then
  check_field "$MARKETPLACE_JSON" 'has("name")'    'top-level "name"'
  check_field "$MARKETPLACE_JSON" 'has("owner")'   'top-level "owner"'
  check_field "$MARKETPLACE_JSON" 'has("plugins")' 'top-level "plugins"'
  check_field "$MARKETPLACE_JSON" '.plugins | type == "array"' '.plugins to be an array'
  check_field "$MARKETPLACE_JSON" '.plugins | length > 0'      '.plugins to be non-empty'
  check_field "$MARKETPLACE_JSON" '.plugins | all(has("name"))'        'every plugin to have "name"'
  check_field "$MARKETPLACE_JSON" '.plugins | all(has("source"))'      'every plugin to have "source"'
  check_field "$MARKETPLACE_JSON" '.plugins | all(has("description"))' 'every plugin to have "description"'

  # Cross-marketplace dependency allowlist (Story 078). Schema per Claude Code docs:
  # https://code.claude.com/docs/en/plugin-dependencies
  # The root marketplace must allowlist any foreign marketplace its plugins depend on,
  # via `allowCrossMarketplaceDependenciesOn` (array of marketplace-name strings).
  check_field "$MARKETPLACE_JSON" 'has("allowCrossMarketplaceDependenciesOn")' 'top-level "allowCrossMarketplaceDependenciesOn"'
  check_field "$MARKETPLACE_JSON" '.allowCrossMarketplaceDependenciesOn | type == "array"' 'allowlist to be an array'
  check_field "$MARKETPLACE_JSON" '.allowCrossMarketplaceDependenciesOn | index("claude-plugins-official") != null' 'allowlist to include claude-plugins-official'
fi

if [ "$ERRORS" -ne 0 ]; then
  echo
  echo "$ERRORS error(s) — see above"
  exit 1
fi

echo "OK — plugin.json + marketplace.json parse and have required fields"
exit 0
