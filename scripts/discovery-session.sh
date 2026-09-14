#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == start ]]; then ./scripts/build-discovery-override.sh; fi
exec /bin/bash scripts/discovery-control.sh "${1:-}" "$PWD/.local/DiscoveryOverride.dylib"
