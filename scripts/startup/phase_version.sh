#!/usr/bin/env bash
# Story 152 — phase_version (M-only).
# Read .version; compute delta vs the plugin manifest target; if a
# migration transform is needed, emit ask-human; on confirm dispatch
# to plugin/scripts/migrations/<from>-<target>.sh.
#
# Story-152 ships an empty migrations/ directory; the dispatcher
# handles the no-op case gracefully.

phase_version() {
  local role="$1"
  local version_file="${WOW_ROOT}/implementations/.version"
  local current=""
  if [ -f "$version_file" ]; then
    current=$(tr -d '[:space:]' < "$version_file")
  fi
  local target
  local plugin_json
  plugin_json=$(wow-locate .claude-plugin/plugin.json 2>/dev/null || true)
  if [ -n "$plugin_json" ]; then
    target=$(jq -r .version "$plugin_json" 2>/dev/null || echo "")
  fi

  if [ -z "$current" ]; then
    emit_info "version: .version absent (fresh project; will be set to $target on first M write)"
    return 0
  fi
  if [ -z "$target" ]; then
    emit_info "version: plugin manifest unresolvable; skipping delta check"
    return 0
  fi
  if [ "$current" = "$target" ]; then
    emit_info "version: $current (current matches target)"
    return 0
  fi

  # Delta exists. Look for a migration script.
  local migrations_dir
  migrations_dir=$(wow-locate scripts/migrations 2>/dev/null || true)
  local script_name="${current}-${target}.sh"
  local script_path=""
  if [ -n "$migrations_dir" ] && [ -d "$migrations_dir" ]; then
    [ -f "${migrations_dir}/${script_name}" ] && script_path="${migrations_dir}/${script_name}"
  fi

  if [ -z "$script_path" ]; then
    emit_info "version: delta $current -> $target (no migration transform; M may need to update .version manually)"
    return 0
  fi

  emit_info "version: delta $current -> $target; migration script $script_path queued (run by M after human confirm in full impl)"
  return 0
}
