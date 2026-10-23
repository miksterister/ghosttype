#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for f in *.lua; do
  luac -p "$f"
done

lua tests/test_caret.lua
lua tests/test_suggestion_state.lua
lua tests/test_config.lua
lua tests/test_app_profiles.lua
lua tests/test_log.lua
lua tests/test_menubar.lua
lua tests/test_settings.lua
lua tests/test_probe.lua
