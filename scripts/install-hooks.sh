#!/usr/bin/env bash
#
# Enable the repository's git hooks (.githooks/) for this clone.
# The pre-commit hook checks the staged snapshot before every commit; see
# .githooks/pre-commit for what it runs.

set -euo pipefail

root=$(git rev-parse --show-toplevel)
current=$(git -C "$root" config --get core.hooksPath || true)

if [ -n "$current" ] && [ "$current" != .githooks ]; then
  echo "core.hooksPath is already set to '$current'; not overriding it." >&2
  echo "To switch anyway: git -C '$root' config core.hooksPath .githooks" >&2
  exit 1
fi

chmod +x "$root/.githooks/"*
git -C "$root" config core.hooksPath .githooks
echo "Git hooks enabled for $root"
echo "Every commit now runs .githooks/pre-commit; skip it once with: git commit --no-verify"
