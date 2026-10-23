#!/usr/bin/env bash
# Links the Hammerspoon module and installs the two launchd services
# (not started — GhostType kickstarts them when it is enabled).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p ~/.hammerspoon ~/Library/LaunchAgents ~/Library/Logs
ln -sfn "$REPO" ~/.hammerspoon/ghosttype
for name in server spellcheck; do
  label="com.local.ghosttype-$name"
  dst=~/Library/LaunchAgents/$label.plist
  sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" "$REPO/deploy/launchd/$label.plist" > "$dst"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$dst"
done
echo "Installed. Add  require(\"ghosttype\")  to ~/.hammerspoon/init.lua and reload Hammerspoon."
