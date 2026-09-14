#!/bin/bash
# Build, migrate the original Python-based example, and open the native app.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  '') ./scripts/build.sh ;;
  --skip-build) ;;
  *) echo 'Usage: scripts/install.sh [--skip-build]' >&2; exit 2 ;;
esac
product="$PWD/.build/Build/Products/Debug/Claude.app"
target="$HOME/Applications/Claude.app"
legacy="$HOME/Applications/GoldenGateClaude.app"
backup_dir="$PWD/.local/install-backups/$(date +%Y%m%d-%H%M%S)"
[[ -d "$product" ]] || { echo 'Build Claude.app first.' >&2; exit 1; }
codesign --verify --deep --strict "$product"
for candidate in "$target" "$legacy"; do
  if [[ -e "$candidate" ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$candidate/Contents/Info.plist")
    [[ "$identifier" == dev.goldengate.Claude ]] || {
      echo "Refusing to replace a different app at $candidate" >&2; exit 1;
    }
  fi
done
mkdir -p "$backup_dir" "$HOME/Applications"
chmod 700 "$backup_dir"
# Back up before replacing a bundle. Compressed backups aren't indexed as apps.
for candidate in "$target" "$legacy"; do
  if [[ -d "$candidate" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$candidate" "$backup_dir/$(basename "$candidate").zip"
  fi
done
# Match exact executable paths so Anthropic's /Applications/Claude.app is untouched.
while read -r pid executable; do
  if [[ "$executable" == "$legacy/Contents/MacOS/GoldenGateClaude" ||
        "$executable" == "$target/Contents/MacOS/Claude" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt=0; attempt<30; attempt++)); do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "The existing example app is still quitting. Try installation again." >&2
      exit 1
    fi
  fi
done < <(ps -ax -o pid=,comm=)
label=dev.goldengate.Claude.Bridge
plist="$HOME/Library/LaunchAgents/$label.plist"
if [[ -f "$plist" ]]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  mv "$plist" "$backup_dir/$label.plist"
fi
for candidate in "$target" "$legacy"; do
  if [[ -d "$candidate" ]]; then rm -rf "$candidate"; fi
done
ditto "$product" "$target"
codesign --verify --deep --strict "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
# Force a new launch after replacement; LaunchServices can briefly retain the
# terminated instance under this same bundle identifier.
open -n "$target"
echo "Installed $target. Use its menu bar settings to test Claude and enable Spotlight discovery."
