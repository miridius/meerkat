#!/usr/bin/env bash
# Build + install meerkat for the current host: scripts/install.ts does
# the work. When mise is here, this first installs the Bun that runs it
# through mise, since Bun may not exist yet.
set -euo pipefail

cd "$(dirname "$0")/.."

if command -v mise >/dev/null; then
  mise install bun
  mise_env=$(mise env --shell bash)
  eval "$mise_env"
fi
exec bun scripts/install.ts "$@"
