#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
mkdir -p .local/AppResources
if [[ ! -f .local/bridge.json ]]; then
  (umask 077; printf '{"port":17839,"token":"%s"}\n' "$(openssl rand -hex 32)" > .local/bridge.json)
fi
cp .local/bridge.json Sources/Extension/bridge.json
cp .local/bridge.json .local/AppResources/bridge.json
./scripts/build-discovery-override.sh
cp .local/DiscoveryOverride.dylib .local/AppResources/
cp scripts/discovery-control.sh .local/AppResources/
xcodegen generate
xcodebuild -project GoldenGateClaude.xcodeproj -scheme GoldenGateClaude -configuration Debug -derivedDataPath .build build
