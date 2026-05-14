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
fi

if [ "$ERRORS" -ne 0 ]; then
  echo
  echo "$ERRORS error(s) — see above"
  exit 1
fi

echo "OK — plugin.json + marketplace.json parse and have required fields"
exit 0
