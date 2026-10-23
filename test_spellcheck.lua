-- GhostType · test_spellcheck.lua
-- Runnable check for the offset conversions in spellcheck.lua. Three coordinate
-- systems meet in this module — AX speaks UTF-16, Lua speaks bytes, the server
-- speaks codepoints — and getting one wrong replaces the wrong span, which
-- corrupts the user's text silently. That is worth a test.
--
-- Run:  lua test_spellcheck.lua

_G.hs = _G.hs or {}
package.path = "./?.lua;" .. package.path
local sc = require("spellcheck")

local pass, fail = 0, 0
local function eq(got, want, label)
  if got == want then pass = pass + 1
  else fail = fail + 1
    print(string.format("FAIL %s: got %q want %q", label, tostring(got), tostring(want)))
  end
end

-- utf16len: ASCII == length, umlauts still 1 unit each, emoji are surrogate pairs
eq(sc._utf16len("hello"), 5, "utf16len ascii")
eq(sc._utf16len("überprüfen"), 10, "utf16len umlauts are 1 unit")
eq(sc._utf16len("a😀b"), 4, "utf16len emoji is 2 units")
eq(sc._utf16len(""), 0, "utf16len empty")

-- cpToByte: codepoint offset (0-based) -> byte index (1-based)
eq(sc._cpToByte("hello", 0), 1, "cpToByte start")
eq(sc._cpToByte("hello", 3), 4, "cpToByte ascii")
eq(sc._cpToByte("über", 2), 4, "cpToByte after a 2-byte char")
eq(sc._cpToByte("über", 0), 1, "cpToByte start of accented")
eq(sc._cpToByte("hello", 5), 6, "cpToByte end is one past")

-- the round trip that actually matters: server says "chars 6..10 of this
-- string"; we must slice exactly those characters out of the Lua bytes.
local s = "Die Prüfung war gut"
local a, b = sc._cpToByte(s, 4), sc._cpToByte(s, 11)
eq(s:sub(a, b - 1), "Prüfung", "cpToByte slices an accented word exactly")

local s2 = "Its a well know fact"
local a2, b2 = sc._cpToByte(s2, 6), sc._cpToByte(s2, 15)
eq(s2:sub(a2, b2 - 1), "well know", "cpToByte slices a multi-word span")

-- utf16ToByte: AX caret offset -> byte index
eq(sc._utf16ToByte("hello", 0), 1, "utf16ToByte start")
eq(sc._utf16ToByte("über", 2), 4, "utf16ToByte after accent")
eq(sc._utf16ToByte("a😀b", 3), 6, "utf16ToByte past a surrogate pair")

-- paragraphBounds: the block around the caret, not the whole document
local doc = "First para.\nSecond para here.\nThird."
local ps, pe = sc._paragraphBounds(doc, 15)
eq(doc:sub(ps, pe), "Second para here.", "paragraphBounds middle")
ps, pe = sc._paragraphBounds(doc, 3)
eq(doc:sub(ps, pe), "First para.", "paragraphBounds first")
ps, pe = sc._paragraphBounds(doc, 32)
eq(doc:sub(ps, pe), "Third.", "paragraphBounds last, no trailing newline")
ps, pe = sc._paragraphBounds("only one line", 5)
eq(("only one line"):sub(ps, pe), "only one line", "paragraphBounds single line")

-- spliceText: replace one span by codepoint offsets
eq(sc._spliceText("Its a fact", 0, 3, "It's"), "It's a fact", "spliceText start")
eq(sc._spliceText("is more stronger", 3, 16, "stronger"), "is stronger", "spliceText tail")
eq(sc._spliceText("Die Prufung war gut", 4, 11, "Prüfung"), "Die Prüfung war gut", "spliceText accented")

-- rebaseIssues: this is what lets you accept 2 of 5. Everything AFTER the
-- accepted span shifts by the length delta; everything before is untouched.
do
  local issues = {
    { start = 0,  ["end"] = 3,  original = "Its",       suggestion = "It's" },
    { start = 6,  ["end"] = 15, original = "well know", suggestion = "well-known" },
    { start = 54, ["end"] = 58, original = "dont",      suggestion = "doesn't" },
  }
  -- accept #1: "Its"(3) -> "It's"(4), delta +1
  local out = sc._rebaseIssues(issues, 1, 1)
  eq(#out, 2, "rebase drops the accepted one")
  eq(out[1].start, 7, "later issue shifted by +1")
  eq(out[2].start, 55, "second later issue shifted too")
  eq(out[1].original, "well know", "payload preserved")

  -- accept the LAST one: nothing moves
  local out2 = sc._rebaseIssues(issues, 3, 3)
  eq(#out2, 2, "two remain")
  eq(out2[1].start, 0, "earlier issue untouched")
  eq(out2[2].start, 6, "earlier issue untouched")

  -- a shrinking edit shifts backwards
  local out3 = sc._rebaseIssues(issues, 1, -2)
  eq(out3[1].start, 4, "negative delta moves left")
end

-- an issue overlapping the accepted span is dropped, not mis-shifted
do
  local issues = {
    { start = 0,  ["end"] = 10, original = "a b",  suggestion = "c d" },
    { start = 5,  ["end"] = 12, original = "over", suggestion = "lap" },
    { start = 20, ["end"] = 24, original = "late", suggestion = "soon" },
  }
  local out = sc._rebaseIssues(issues, 1, 1)
  eq(#out, 1, "overlapping issue dropped rather than guessed at")
  eq(out[1].original, "late", "the safe one survives")
end


-- unitBounds: a non-empty selection is the unit to check (multi-line is fine);
-- a collapsed caret falls back to the paragraph. Both in bytes.
local v = "first line\nsecond line\nthird"
local s1, e1 = sc._unitBounds(v, 3, 0)          -- caret in "first line"
eq(v:sub(s1, e1), "first line", "caret -> paragraph")
local s2, e2 = sc._unitBounds(v, 6, 13)         -- "line\nsecond l" selected (UTF-16 loc/len)
eq(v:sub(s2, e2), "line\nsecond l", "selection -> exactly the selection")
local s3, e3 = sc._unitBounds("a😀b\nc", 4, 1)  -- emoji is 2 UTF-16 units; "b" is at loc 3, "\n" at 4
eq(("a😀b\nc"):sub(s3, e3), "\n", "selection offsets are UTF-16")

-- rowContext: a few words before the span so a fragment row reads as a sentence
eq(sc._rowContext("There going to there house, their late.", 15, 2), "going to", "last words before span")
eq(sc._rowContext("There going", 0, 3), "", "nothing before the span")
eq(sc._rowContext("a b c d e f", 10, 2), "d e", "capped at n words")
print(string.format("test_spellcheck.lua: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
