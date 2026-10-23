#!/usr/bin/env bash
# Checks that toggling GhostType starts and stops the MLX server, i.e. that the
# launchd agent really is on-demand (RunAtLoad=false, no KeepAlive) and that the
# toggle drives it. Live check — needs Hammerspoon running with the config loaded.
#
# Guards the launchctl asymmetry that already bit once: `kickstart` takes a
# domain-qualified target, legacy `stop` does not and exits 3 while doing
# nothing, so the "off" half must use `kill`. A silent no-op there looks fine in
# the UI and leaves the model resident forever, which is the whole bug this
# check exists to catch.
#
#   ./tests/check_server_lifetime.sh
set -uo pipefail

PORT="${GHOSTTYPE_PORT:-8790}"
LABEL="com.local.ghosttype-server"
BOOT_WAIT=25   # cold start loads the model
STOP_WAIT=10
fails=0

listening() { [ -n "$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null)" ]; }

# Polls instead of sleeping a fixed amount: a warm start is ~2s, a cold one much
# more, and a fixed sleep either flakes or wastes half a minute.
await() { # await <up|down> <seconds>
  local want=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    if [ "$want" = up ] && listening; then return 0; fi
    if [ "$want" = down ] && ! listening; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

check() { # check <description> <up|down> <seconds>
  if await "$2" "$3"; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1 (still $(listening && echo up || echo down) after ${3}s)"
    fails=$((fails + 1))
  fi
}

pgrep -x Hammerspoon >/dev/null || { echo "Hammerspoon is not running"; exit 1; }

echo "plist is on-demand:"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
for want in "RunAtLoad:false" "KeepAlive:absent"; do
  key=${want%%:*}; expect=${want##*:}
  got=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || echo absent)
  if [ "$got" = "$expect" ]; then echo "  ok    $key = $expect"
  else echo "  FAIL  $key = $got, want $expect"; fails=$((fails + 1)); fi
done

# Start from a known-off state so the first check cannot pass by accident.
hs -c 'require("ghosttype").setEnabled(false)' >/dev/null 2>&1
await down "$STOP_WAIT" || { echo "could not reach a stopped baseline"; exit 1; }

echo "toggle drives the server:"
hs -c 'require("ghosttype").setEnabled(true)'  >/dev/null 2>&1
check "on  -> server starts" up "$BOOT_WAIT"
hs -c 'require("ghosttype").setEnabled(false)' >/dev/null 2>&1
check "off -> server stops" down "$STOP_WAIT"
sleep 5
check "off -> stays stopped (no KeepAlive resurrect)" down 1

[ "$fails" -eq 0 ] && echo "PASS" || echo "$fails check(s) failed"
exit "$fails"
