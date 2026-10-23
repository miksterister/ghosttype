-- GhostType · test_caret.lua
-- Runnable check for the caret prefix slice — the one piece with a real
-- correct/incorrect answer (it used to silently truncate accented text).
--
-- Run:  lua test_caret.lua      (needs Lua 5.3+ for the utf8 library, which
--                                is also what Hammerspoon bundles)

-- caret.lua references `hs` only in AX code paths we don't exercise here; a
-- stub keeps `require` happy so we can test the pure prefixForCaret function.
_G.hs = _G.hs or {}
package.path = "./?.lua;" .. package.path
local caret = require("caret")

local pass, fail = 0, 0
local function eq(got, want, label)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %q want %q", label, tostring(got), tostring(want)))
  end
end

-- Plain ASCII: byte offset == UTF-16 offset, trivially correct.
eq(caret.prefixForCaret("hello world", 5), "hello", "ascii mid")
eq(caret.prefixForCaret("hello", 0), "", "ascii start")
eq(caret.prefixForCaret("hello", 5), "hello", "ascii end")

-- Accented Latin (BMP, 2 UTF-8 bytes / 1 UTF-16 unit each) — the case the old
-- byte-count math got wrong. "über " is u ü b e r space; caret after "über"
-- is 4 UTF-16 units in, which is byte 6 (ü is 2 bytes). Byte-count math would
-- have cut at byte 4 → "üb\xNN" garbage. This must land exactly on "über".
eq(caret.prefixForCaret("über alles", 4), "über", "umlaut word boundary")
eq(caret.prefixForCaret("Grüße", 3), "Grü", "umlaut mid")

-- Out-of-range caret (AX can momentarily report a stale offset) must not throw
-- and must clamp to the whole string rather than erroring.
eq(caret.prefixForCaret("hi", 99), "hi", "loc past end clamps")
eq(caret.prefixForCaret("", 0), "", "empty field")

print(string.format("caret: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
