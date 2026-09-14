#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
xcrun clang -dynamiclib -arch arm64 -arch arm64e hooks/DiscoveryOverride.c -o .local/DiscoveryOverride.dylib
codesign --force --sign - .local/DiscoveryOverride.dylib
