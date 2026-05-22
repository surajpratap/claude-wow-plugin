#!/usr/bin/env bash
# contract-golden.sh — sourceable helper for contract tests (Story 141).
#
#   source "<plugin>/tests/lib/contract-golden.sh"
#   assert_fixture_matches_golden <golden-name> <fixture-json> [<required-keys-csv>]
#
# Compares a test's inline fixture against the REAL captured golden in
# tests/fixtures/golden/<golden-name>.json by RECURSIVE shape signature —
# the set of `<dotted-path>:<json-type>` over ALL paths (containers + leaves),
# excluding any path under `_provenance`. NOT top-level keys: that can't catch a
# flat `in_reply_to` string vs the nested `{ts}` object (FINDING-32), nor a
# `payload` string-vs-object, nor a manifest array-vs-string.
#
# FAILS (returns 1, prints to stderr) when the fixture:
#   - uses a PATH absent from the golden (wrong/extra key — FINDING-36 `pr_base`,
#     FINDING-37 `story_id`), OR
#   - has a shared path whose TYPE differs from the golden (FINDING-32), OR
#   - omits a key named in the optional <required-keys-csv> (top-level).
# A fixture that is a shape-compatible SUBSET of the golden passes (rich real
# goldens — e.g. a 14-key manifest item — must not force every consumer fixture
# to carry all keys; required-keys is the opt-in tightening).
#
# Sourced, not executed; run-all globs tests/*.sh (top-level), not tests/lib/.

# Emit sorted-unique `<dotted-path>:<type>` lines for a JSON value on stdin,
# skipping any path beginning with `_provenance`.
_cg_shape_sig() {
  jq -r '
    paths as $p
    | select($p[0] != "_provenance")
    | (($p | map(tostring)) | join(".")) + ":" + (getpath($p) | type)
  ' | LC_ALL=C sort -u
}

# assert_fixture_matches_golden <golden-name> <fixture-json> [<required-keys-csv>]
assert_fixture_matches_golden() {
  local name="$1" fixture="$2" required="${3:-}"
  local dir golden gsig fsig fail=0 path ptype gtype

  dir="${CONTRACT_GOLDEN_DIR:-}"
  if [ -z "$dir" ]; then
    # default: tests/fixtures/golden relative to this lib (lib/ -> tests/ -> fixtures/golden)
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/golden" && pwd)"
  fi
  golden="$dir/$name.json"
  if [ ! -f "$golden" ]; then
    echo "assert_fixture_matches_golden: golden not found — $golden" >&2
    return 1
  fi
  if ! printf '%s' "$fixture" | jq -e . >/dev/null 2>&1; then
    echo "assert_fixture_matches_golden: fixture is not valid JSON" >&2
    return 1
  fi

  gsig=$(printf '%s' "$(cat "$golden")" | _cg_shape_sig)
  fsig=$(printf '%s' "$fixture" | _cg_shape_sig)

  # (1) every fixture path must exist in the golden with a matching TYPE.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    path="${line%:*}"; ptype="${line##*:}"
    gtype=$(printf '%s\n' "$gsig" | sed -n "s|^${path}:||p" | head -1)
    if [ -z "$gtype" ]; then
      echo "assert_fixture_matches_golden[$name]: fixture path '$path' is ABSENT from the golden (wrong/extra key)" >&2
      fail=1
    elif [ "$gtype" != "$ptype" ]; then
      echo "assert_fixture_matches_golden[$name]: path '$path' type '$ptype' != golden '$gtype' (shape mismatch)" >&2
      fail=1
    fi
  done <<EOF
$fsig
EOF

  # (2) optional required top-level keys must be present in the fixture.
  if [ -n "$required" ]; then
    local key
    local IFS=,
    for key in $required; do
      [ -z "$key" ] && continue
      if ! printf '%s' "$fixture" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1; then
        echo "assert_fixture_matches_golden[$name]: required key '$key' missing from fixture" >&2
        fail=1
      fi
    done
  fi

  return "$fail"
}
