#!/usr/bin/env bash
# Backwards-compat shim — relocated in v3.3.0 to scripts/wow-process/bus-tail.sh.
exec bash "$(dirname "$0")/wow-process/bus-tail.sh" "$@"
