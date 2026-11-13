#!/usr/bin/env bash
#
# interactive-claude.sh '<prompt>' [timeout_seconds]
#
# Compatibility wrapper kept for the original single-prompt interface. The
# implementation lives in bin/claude-interactive (see docs/usage.md); use it
# directly for multi-turn runs, JSON reports and the other options.

set -euo pipefail

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 '<prompt>' [timeout_seconds]" >&2
  exit 2
fi

here=$(cd "$(dirname "$0")" && pwd -P)
exec "$here/../bin/claude-interactive" run \
  --timeout "${2:-300}" \
  --output-dir "${GITHUB_WORKSPACE:-.}/logs" \
  -- "$1"
