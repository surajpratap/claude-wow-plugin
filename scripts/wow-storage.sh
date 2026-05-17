#!/usr/bin/env bash
# wow-storage.sh — home-dir cred + info storage helper for the claude-wow plugin.
#
# Source this file or invoke as a CLI:
#   source scripts/wow-storage.sh && wow_storage_init
#   bash scripts/wow-storage.sh init
#
# Storage root: ${WOW_HOME:-$HOME/.wow-kindflow}
# Schema version: 1.0.0 (initial)
#
# Layout:
#   $WOW_HOME/.version                              plain text "1.0.0" (mode 0700 dir)
#   $WOW_HOME/<scope>/<project-key>/creds.json      mode 0600 (dir mode 0700)
#
# <project-key> = $(git rev-parse --show-toplevel) with `/` substituted to `_`,
# leading underscore stripped.
#
# All writes use atomic-rename (.tmp.<pid>.<random> + mv). All cred files are
# explicit `chmod 0600` after rename. All directories created at mode 0700.
#
# Manual wipe (no auto-cleanup on plugin uninstall):
#   rm -rf ~/.wow-kindflow/

umask 077

WOW_HOME="${WOW_HOME:-$HOME/.wow-kindflow}"
WOW_HOME_VERSION="1.0.0"

_wow_storage_err() {
  printf '%s\n' "$*" >&2
}

wow_storage_init() {
  if [ ! -d "$WOW_HOME" ]; then
    mkdir -p "$WOW_HOME"
    chmod 0700 "$WOW_HOME"
  fi
  if [ ! -f "$WOW_HOME/.version" ]; then
    printf '%s\n' "$WOW_HOME_VERSION" > "$WOW_HOME/.version.tmp.$$.$RANDOM"
    mv -f "$WOW_HOME/.version.tmp.$$".* "$WOW_HOME/.version"
    chmod 0600 "$WOW_HOME/.version"
  fi
  # Startup sweep: remove stale .tmp.* files (>60 min old) per spec Section J.
  find "$WOW_HOME" -name '.tmp.*' -mmin +60 -delete 2>/dev/null || true
  find "$WOW_HOME" -name '*.tmp.[0-9]*.[0-9]*' -mmin +60 -delete 2>/dev/null || true
}

wow_storage_get() {
  local scope="$1" key="$2" field="$3"
  if [ -z "$scope" ] || [ -z "$key" ] || [ -z "$field" ]; then
    _wow_storage_err "wow_storage_get: usage: wow_storage_get <scope> <key> <field>"
    return 2
  fi
  local file="$WOW_HOME/$scope/$key/creds.json"
  if [ ! -f "$file" ]; then
    _wow_storage_err "wow_storage_get: $file does not exist"
    return 1
  fi
  local value
  value=$(jq -er --arg f "$field" '.[$f]' "$file" 2>/dev/null)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    _wow_storage_err "wow_storage_get: field '$field' not found in $file"
    return 1
  fi
  printf '%s\n' "$value"
}

wow_storage_set() {
  local scope="$1" key="$2" field="$3" value="$4"
  if [ -z "$scope" ] || [ -z "$key" ] || [ -z "$field" ]; then
    _wow_storage_err "wow_storage_set: usage: wow_storage_set <scope> <key> <field> <value>"
    _wow_storage_err "                     wow_storage_set <scope> <key> <field> --from-stdin"
    return 2
  fi
  if [ "$value" = "--from-stdin" ]; then
    IFS= read -r value
  fi
  local dir="$WOW_HOME/$scope/$key"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    chmod 0700 "$dir"
    # Also enforce on intermediate scope dir.
    chmod 0700 "$WOW_HOME/$scope"
  fi
  local file="$dir/creds.json"
  local existing='{}'
  if [ -f "$file" ]; then
    existing=$(cat "$file")
  fi
  local tmp="$file.tmp.$$.$RANDOM"
  printf '%s' "$existing" | jq --arg f "$field" --arg v "$value" '. + {($f): $v}' > "$tmp"
  mv -f "$tmp" "$file"
  chmod 0600 "$file"
}

wow_storage_list() {
  local scope="$1"
  if [ -z "$scope" ]; then
    _wow_storage_err "wow_storage_list: usage: wow_storage_list <scope>"
    return 2
  fi
  local dir="$WOW_HOME/$scope"
  if [ ! -d "$dir" ]; then
    return 0
  fi
  ls -1 "$dir" 2>/dev/null
}

wow_storage_wipe() {
  local scope="$1" key="$2" force="${3:-}"
  if [ -z "$scope" ] || [ -z "$key" ]; then
    _wow_storage_err "wow_storage_wipe: usage: wow_storage_wipe <scope> <key> --force"
    return 2
  fi
  if [ "$force" != "--force" ]; then
    _wow_storage_err "wow_storage_wipe: refusing to wipe without --force flag"
    return 2
  fi
  local dir="$WOW_HOME/$scope/$key"
  if [ -d "$dir" ]; then
    rm -rf "$dir"
  fi
}

_wow_storage_help() {
  cat <<'HELP'
wow-storage.sh — home-dir cred + info storage helper

Subcommands (CLI mode: bash scripts/wow-storage.sh <subcmd> ...):
  init                                      Create $WOW_HOME and .version (idempotent)
  get <scope> <key> <field>                 Print field value; exit 1 if missing
  set <scope> <key> <field> <value>         Write field (atomic rename, 0600)
  set <scope> <key> <field> --from-stdin    Read value from stdin (avoids argv leak)
  list <scope>                              List project keys under scope
  wipe <scope> <key> --force                Remove the project key dir (refuses without --force)

Storage root: ${WOW_HOME:-$HOME/.wow-kindflow}
Schema version: 1.0.0

Manual wipe (no auto-cleanup on plugin uninstall):
  rm -rf ~/.wow-kindflow/
HELP
}

# CLI shim — only runs if executed directly, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  subcmd="${1:-}"
  shift 2>/dev/null || true
  case "$subcmd" in
    init|get|set|list|wipe) "wow_storage_$subcmd" "$@" ;;
    --help|-h|"") _wow_storage_help ;;
    *) _wow_storage_err "unknown subcommand: $subcmd"; _wow_storage_help >&2; exit 2 ;;
  esac
fi
