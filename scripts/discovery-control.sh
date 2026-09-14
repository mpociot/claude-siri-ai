#!/bin/bash
# Shared by the app and command-line wrapper. No build tools required at runtime.
set -euo pipefail
action="${1:-}"
hook="${2:-}"
domain="gui/$(id -u)"
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

case "$action" in
  start)
    [[ -f "$hook" ]] || { echo 'Discovery override is missing.' >&2; exit 1; }
    backup_dir="$HOME/Library/Application Support/dev.goldengate.Claude/DiscoveryBackups"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"
    backup="$backup_dir/provider-settings-$(date +%Y%m%d-%H%M%S).plist"
    defaults export com.apple.generativepartnerservicesettings "$backup"
    chmod 600 "$backup"
    commands=''
    for service in com.apple.generativeexperiencesd com.apple.campo; do
      if [[ "$service" == com.apple.campo ]]; then
        executable='/System/Applications/Siri AI.app/Contents/MacOS/Siri AI'
      else
        executable='/System/Library/PrivateFrameworks/GenerativeExperiencesRuntime.framework/Versions/A/generativeexperiencesd'
      fi
      [[ -z "$commands" ]] || commands+=' && '
      commands+="/bin/launchctl debug $(quote "$domain/$service") --environment $(quote "DYLD_INSERT_LIBRARIES=$hook") -- $(quote "$executable") -useExpandedDiscovery YES"
    done
    # AppleScript string quoting follows shell argument quoting.
    escaped="${commands//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    /usr/bin/osascript -e "do shell script \"$escaped\" with administrator privileges"
    for key in externalProviders externalProvidersSHA256Hash; do
      if defaults read com.apple.generativepartnerservicesettings "$key" >/dev/null 2>&1; then
        defaults delete com.apple.generativepartnerservicesettings "$key"
      fi
    done
    ;;
  stop) ;;
  *) echo 'Usage: discovery-control.sh start|stop /path/to/DiscoveryOverride.dylib' >&2; exit 2 ;;
esac

launchctl kickstart -k "$domain/com.apple.generativeexperiencesd"
launchctl kickstart -k "$domain/com.apple.campo"
if pgrep -x CampoRemoteService >/dev/null; then
  pkill -KILL -x CampoRemoteService || true
fi
echo "Discovery session: $action"
