package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local caret = require("caret")

-- Plain ASCII: byte offset == UTF-16 offset.
T.eq(caret.prefixForCaret("hello world", 5), "hello", "ascii mid")
T.eq(caret.prefixForCaret("hello", 0), "", "ascii start")
T.eq(caret.prefixForCaret("hello", 5), "hello", "ascii end")

-- Accented Latin: multi-byte UTF-8 but one UTF-16 code unit.
T.eq(caret.prefixForCaret("über alles", 4), "über", "umlaut word boundary")
T.eq(caret.prefixForCaret("Grüße", 3), "Grü", "umlaut mid")
T.eq(caret.prefixForCaret("é", 1), "é", "single accented char")

-- Non-BMP emoji: one Unicode code point, two UTF-16 code units.
T.eq(caret.prefixForCaret("😀x", 2), "😀", "emoji utf16 boundary")
T.eq(caret.prefixForCaret("😀x", 3), "😀x", "emoji plus ascii")

-- Out-of-range caret (AX can momentarily report a stale offset) must not throw.
T.eq(caret.prefixForCaret("hi", 99), "hi", "loc past end clamps")
T.eq(caret.prefixForCaret("", 0), "", "empty field")

-- UTF-8-safe suffix trimming: do not split multibyte chars.
T.eq(caret.suffixUtf8Chars("abc", 2), "bc", "suffix ascii")
T.eq(caret.suffixUtf8Chars("aéb", 2), "éb", "suffix accented")
T.eq(caret.suffixUtf8Chars("a😀b", 2), "😀b", "suffix emoji")
T.eq(caret.suffixUtf8Chars("abc", 99), "abc", "suffix no trim")

-- afterForCaret: text after the UTF-16 caret offset
T.eq(caret.afterForCaret("hello world", 5), " world", "afterForCaret ascii")
T.eq(caret.afterForCaret("hello", 5), "", "afterForCaret at end")
T.eq(caret.afterForCaret("héllo", 1), "éllo", "afterForCaret before accented")
T.eq(caret.afterForCaret("a😀b", 1), "😀b", "afterForCaret before emoji (non-BMP)")
T.eq(caret.afterForCaret(nil, 3), "", "afterForCaret nil value")

-- secure field: never suggest inside password fields
T.eq(caret.isSecureField("AXSecureTextField"), true, "secure: password field")
T.eq(caret.isSecureField("AXTextArea"), false, "secure: normal text area")
T.eq(caret.isSecureField(nil), false, "secure: nil subrole")

-- prefixUtf8Chars: first N codepoints, never bisecting a multibyte char
T.eq(caret.prefixUtf8Chars("hello", 3), "hel", "front cap ascii")
T.eq(caret.prefixUtf8Chars("héllo", 2), "hé", "front cap keeps accented char whole")
T.eq(caret.prefixUtf8Chars("a😀b", 2), "a😀", "front cap keeps emoji (non-BMP) whole")
T.eq(caret.prefixUtf8Chars("hi", 9), "hi", "front cap shorter than max")

-- degenerate rect detection
T.eq(caret.isDegenerateRect({x=10, y=20, w=2, h=18}), false, "good rect not degenerate")
T.eq(caret.isDegenerateRect({x=0, y=982, w=0, h=0}), true, "zero w/h is degenerate")
-- CHANGED 2026-09-18: this used to assert w=0 is degenerate, which is wrong and
-- was costing us exact caret bounds in every native Cocoa app. A COLLAPSED
-- CARET HAS NO WIDTH — Notes probed {x=251,y=132,w=0,h=18}, a perfectly good
-- caret that the old predicate threw away in favour of an estimate. HEIGHT is
-- the validity signal (the rule normalizeCaretRect already stated for the
-- marker path). Chromium's junk rect is still caught: it has h=0.
T.eq(caret.isDegenerateRect({x=5, y=5, w=0, h=18}), false, "zero width is a valid collapsed caret")
T.eq(caret.isDegenerateRect({x=5, y=5, w=2, h=0}), true, "zero height is degenerate")
T.eq(caret.isDegenerateRect({x=5, y=5}), true, "missing w/h is degenerate")
T.eq(caret.isDegenerateRect(nil), true, "nil rect is degenerate")

-- normalizeCaretRect: the single rule both the integer-range path and the
-- text-marker path go through, so they cannot disagree about what is usable.
local nr = caret.normalizeCaretRect({x=251, y=132, w=0, h=18})
T.eq(nr and nr.x, 251, "collapsed caret keeps x")
T.eq(nr and nr.h, 18, "collapsed caret keeps h")
T.eq(caret.normalizeCaretRect({x=0, y=982, w=0, h=0}), nil, "chromium placeholder rejected")
T.eq(caret.normalizeCaretRect({x=5, y=5, w=2}), nil, "missing height rejected")
T.eq(caret.normalizeCaretRect(nil), nil, "nil rejected")
T.eq(caret.normalizeCaretRect({y=5, w=2, h=18}), nil, "missing x rejected")
-- An empty field answers with the whole LINE BOX, not a caret. Its left edge is
-- where the caret sits, and overlay.show draws at x + w — so a fat w would fling
-- the ghost to the far right of the field. Flatten it.
local box = caret.normalizeCaretRect({x=681, y=861, w=716, h=18})
T.eq(box and box.w, 0, "line box width flattened to 0")
T.eq(box and box.x, 681, "line box keeps its left edge as the caret x")
local fat = caret.normalizeCaretRect({x=384, y=812, w=6, h=23})
T.eq(fat and fat.w, 0, "a caret wider than 4px is treated as a box edge")
local thin = caret.normalizeCaretRect({x=489, y=475, w=1, h=18})
T.eq(thin and thin.w, 1, "a real thin caret keeps its width")

-- current column: codepoints since the last newline
T.eq(caret.currentColumn("hello"), 5, "column no newline")
T.eq(caret.currentColumn("line one\nabc"), 3, "column after newline")
T.eq(caret.currentColumn("done\n"), 0, "column at line start")
T.eq(caret.currentColumn("café"), 4, "column counts codepoints not bytes")
T.eq(caret.currentColumn(""), 0, "column empty")

-- estimated rect: frame left + leftPad + column*charWidth for x; metric h.
-- rawRect.y is kept ONLY when it lands inside the element frame — Chromium
-- (Claude, Obsidian) puts screen-height garbage in degenerate rects' y.
local est = caret.estimateRect({x=100, y=50, w=600, h=400}, {x=0, y=200, w=0, h=0}, 10,
                               {charWidth=8, lineHeight=20, leftPad=4})
T.eq(est.x, 100 + 4 + 10*8, "estimate x = frame.x + leftPad + col*charWidth")
T.eq(est.y, 200, "estimate keeps in-frame rawRect.y")
T.eq(est.h, 20, "estimate h = metric lineHeight")
T.eq(est.w, 2, "estimate w = caret placeholder width 2")
-- garbage y below the frame (Chromium's screen-height y) clamps into the frame
local garbage = caret.estimateRect({x=345, y=804, w=732, h=45}, {x=0, y=982, w=0, h=0}, 10,
                                   {charWidth=8, lineHeight=20, leftPad=4})
T.eq(garbage.y, 804 + 45 - 20, "out-of-frame y clamps to frame bottom minus line height")
-- garbage y above the frame clamps to the frame top
local above = caret.estimateRect({x=100, y=400, w=600, h=300}, {x=0, y=10, w=0, h=0}, 0,
                                 {charWidth=8, lineHeight=20, leftPad=4})
T.eq(above.y, 400, "y above frame clamps to frame top")
-- frame shorter than a line: y pins to frame top, never above it
local tiny = caret.estimateRect({x=100, y=50, w=600, h=10}, {x=0, y=982, w=0, h=0}, 0,
                                {charWidth=8, lineHeight=20, leftPad=4})
T.eq(tiny.y, 50, "tiny frame pins y to frame top")
-- when rawRect has no y, fall back to frame.y
local est2 = caret.estimateRect({x=100, y=50, w=600, h=400}, nil, 0, {charWidth=8, lineHeight=20, leftPad=4})
T.eq(est2.y, 50, "estimate falls back to frame.y when rawRect.y absent")

-- Soft-wrapped line: column counted since the last hard newline can be huge;
-- x must clamp inside the element frame instead of walking offscreen.
local far = caret.estimateRect({x=100, y=50, w=600, h=400}, {x=0, y=982, w=0, h=0}, 500,
                               {charWidth=8, lineHeight=20, leftPad=4})
T.eq(far.x, 100 + 600 - 40, "estimate x clamps to frame right edge")
local nofw = caret.estimateRect({x=100, y=50}, nil, 500, {charWidth=8, lineHeight=20, leftPad=4})
T.eq(nofw.x, 100 + 4 + 500*8, "no frame width means no clamp")

T.finish("caret")
