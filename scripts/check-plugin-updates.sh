#!/usr/bin/env bash
# check-plugin-updates.sh — query the latest stable release of a GitHub repo
# and compare to the local .claude-plugin/plugin.json version. Emit
# `update-available <local> <latest> <url>` to stdout if newer.
#
# Story 057. Sourceable + CLI-invocable.
#
# Usage: bash scripts/check-plugin-updates.sh [<owner/repo>]
#   Default repo: nedati-technologies/claude-wow-plugin
#
# Behavior:
# - Reads local version from $ROOT/.claude-plugin/plugin.json (.version).
#   ROOT discovered via `git rev-parse --show-toplevel` when unset.
# - Fetches latest stable via `gh release view --repo <repo>` (no tag arg
#   returns the latest non-draft non-prerelease).
# - PP nit guard: validates BOTH local and latest as bare semver (X.Y.Z)
#   via regex BEFORE the integer compare; non-conformant version → silent
#   skip (stderr warning, no stdout, exit 0).
# - On gh failure: stderr warning, no stdout, exit 0 (graceful skip).
# - On `latest > local`: prints `update-available <local> <latest> <url>`.
# - On match or local > latest (dev ahead of release): no stdout.
# - Always exits 0. Stderr is the diagnostic channel; stdout is the signal.

set -u

# Validate vMAJOR.MINOR.PATCH (bare semver, 3 numeric components).
# Returns 0 if valid, 1 if not. Used to guard the integer compare.
_is_bare_semver() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Compare two bare-semver strings. Echoes "lt" / "eq" / "gt" describing the
# relationship of $1 to $2 (e.g. _semver_cmp 1.2.3 2.0.0 → "lt").
# Caller is responsible for validating with _is_bare_semver first.
_semver_cmp() {
  local a="$1" b="$2"
  IFS=. read -r am an ap <<<"$a"
  IFS=. read -r bm bn bp <<<"$b"
  if   [ "$am" -lt "$bm" ]; then echo "lt"
  elif [ "$am" -gt "$bm" ]; then echo "gt"
  elif [ "$an" -lt "$bn" ]; then echo "lt"
  elif [ "$an" -gt "$bn" ]; then echo "gt"
  elif [ "$ap" -lt "$bp" ]; then echo "lt"
  elif [ "$ap" -gt "$bp" ]; then echo "gt"
  else echo "eq"
  fi
}

_check_plugin_updates() {
  local repo="${1:-nedati-technologies/claude-wow-plugin}"

  local root="${ROOT:-}"
  if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
  local plugin_json
  if [ -f "$root/plugin/.claude-plugin/plugin.json" ]; then
    plugin_json="$root/plugin/.claude-plugin/plugin.json"
  else
    plugin_json="$root/.claude-plugin/plugin.json"
  fi
  if [ ! -f "$plugin_json" ]; then
    echo "check-plugin-updates: $plugin_json not found — skipping" >&2
    return 0
  fi

  local local_v
  local_v=$(jq -r '.version // empty' "$plugin_json" 2>/dev/null)
  if ! _is_bare_semver "$local_v"; then
    echo "check-plugin-updates: local version '$local_v' is not bare semver — skipping" >&2
    return 0
  fi

  local gh_out
  gh_out=$(gh release view --repo "$repo" --json tagName,url 2>/dev/null)
  local rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$gh_out" ]; then
    echo "check-plugin-updates: gh failed (auth/network/repo missing) — skipping" >&2
    return 0
  fi

  local tag url latest_v
  tag=$(echo "$gh_out" | jq -r '.tagName // empty')
  url=$(echo "$gh_out" | jq -r '.url // empty')
  latest_v="${tag#v}"
  if ! _is_bare_semver "$latest_v"; then
    echo "check-plugin-updates: latest tag '$tag' is not bare semver after v-strip — skipping" >&2
    return 0
  fi

  local cmp
  cmp=$(_semver_cmp "$local_v" "$latest_v")
  if [ "$cmp" = "lt" ]; then
    echo "update-available $local_v $latest_v $url"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  return 0 2>/dev/null || true
fi

_check_plugin_updates "$@"
