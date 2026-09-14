#!/bin/bash
set -euo pipefail
app="$HOME/Applications/Claude.app"
exec "$app/Contents/MacOS/Claude" --smoke-test
