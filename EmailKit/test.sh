#!/bin/bash
# Runs EmailKit unit tests.
#
# Build output is routed to a scratch path OUTSIDE the (iCloud/sync-backed)
# Projects directory, which otherwise triggers "disk I/O error" / dlopen
# failures on the default `.build` dir (same quirk as AetherKit).
set -euo pipefail

SCRATCH="${EMAILKIT_SCRATCH:-$(mktemp -d)/emailkit-build}"
cd "$(dirname "$0")"
exec swift test --scratch-path "$SCRATCH" "$@"
