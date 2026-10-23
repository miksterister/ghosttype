package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local probe = require("probe")

-- ── verdict: the four capability outcomes ────────────────────────────────────
-- The verdict order mirrors caret.getFocusedContext exactly: element → secure →
-- AXValue → range/markers → bounds. A probe that answers differently from the
-- live path is worse than no probe.

-- A Lua table literal cannot carry a nil value ({value = nil} is just {}), so
-- "this attribute is absent" needs an explicit sentinel — otherwise every
-- absent-attribute case silently tests the defaults instead.
local ABSENT = setmetatable({}, { __tostring = function() return "ABSENT" end })

local function facts(over)
  local f = {
    hasElement = true, secure = false,
    value = "hello world", range = { loc = 5, len = 0 },
    rect = { x = 100, y = 200, w = 2, h = 18 },
    markers = false,
  }
  for k, v in pairs(over or {}) do
    if v == ABSENT then f[k] = nil else f[k] = v end -- `and/or` would eat a false
  end
  return f
end

-- Guard the guard: if the sentinel ever stops removing keys, these cases would
-- quietly go back to testing the defaults and passing for the wrong reason.
T.eq(facts({ value = ABSENT }).value, nil, "ABSENT sentinel removes the key")
T.eq(facts({}).value, "hello world", "no override keeps the default")
T.eq(facts({ secure = false }).secure, false, "a false override survives as false")

-- full: everything the fast path needs (Notes, Mail, Claude)
T.eq(probe.verdict(facts()), "full", "full when value+range+usable bounds")

-- estimated: no real geometry AND no markers to rescue it
T.eq(probe.verdict(facts({ rect = { x = 0, y = 0, w = 0, h = 0 }, markers = false })), "estimated",
  "estimated when bounds are unusable and markers are absent")

-- markers rescue an unusable rect — this is what Chromium apps (Claude, Notion,
-- Teams, AFFiNE, Anytype) actually do, and the live path prefers it to estimating.
T.eq(probe.verdict(facts({ rect = { x = 0, y = 982, w = 0, h = 0 }, markers = true })), "markers",
  "markers beat an unusable rect")

-- A collapsed caret is NOT unusable: w=0 with a real height is exactly what
-- every native Cocoa app reports (Notes {x=251,y=132,w=0,h=18}).
T.eq(probe.verdict(facts({ rect = { x = 251, y = 132, w = 0, h = 18 } })), "full",
  "collapsed caret probes full, not estimated")

-- markers: WebKit web areas (Mail compose) speak text markers, not a range
T.eq(probe.verdict(facts({ range = ABSENT, markers = true })), "markers",
  "markers when no range but marker path present")

-- no-go: each way the live path bails out
T.eq(probe.verdict(facts({ hasElement = false })), "no-go", "no-go without a focused element")
T.eq(probe.verdict(facts({ secure = true })), "no-go", "no-go in a secure field")
T.eq(probe.verdict(facts({ value = ABSENT })), "no-go", "no-go without AXValue")
T.eq(probe.verdict(facts({ value = 42 })), "no-go", "no-go when AXValue is not a string")
T.eq(probe.verdict(facts({ range = ABSENT, markers = false })), "no-go",
  "no-go with neither range nor markers")
T.eq(probe.verdict(facts({ rect = ABSENT })), "no-go", "no-go without caret bounds")

-- retry: a live selection is the prober's own doing, not an app limitation.
-- Reporting it as no-go would libel an app that actually works fine.
T.eq(probe.verdict(facts({ range = { loc = 2, len = 3 } })), "retry",
  "retry when text is selected")

-- An empty AXValue is still a working field — an empty Notes note probes full.
T.eq(probe.verdict(facts({ value = "", range = { loc = 0, len = 0 } })), "full",
  "empty value still full")

-- ── reason: every verdict carries a human-readable why ───────────────────────
local _, whyNoValue = probe.verdict(facts({ value = ABSENT }))
T.eq(whyNoValue, "no AXValue", "reason names the missing attribute")
local _, whyFull = probe.verdict(facts())
T.eq(whyFull, "AXValue + AXSelectedTextRange + usable AXBoundsForRange", "reason for full")

-- ── summary: the one line that lands in the alert ────────────────────────────
T.eq(probe.summary("Microsoft Word", "no-go", "no AXValue"),
  "Microsoft Word → NO-GO (no AXValue)", "summary line")
-- The role disambiguates a verdict that would otherwise flatter a non-text element
T.eq(probe.summary("Arc", "estimated", "why", "AXGroup"),
  "Arc → ESTIMATED (why) [AXGroup]", "summary carries the role")
T.eq(probe.summary("Notes", "full", "why", ""), "Notes → FULL (why)",
  "empty role adds no brackets")

-- ── format: the detail block appended to the probe log ───────────────────────
local block = probe.format("Notes", facts({ role = "AXTextArea", subrole = "" }), "full", "why")
T.ok(block:find("app=Notes", 1, true), "format names the app")
T.ok(block:find("verdict=full", 1, true), "format names the verdict")
T.ok(block:find("AXRole=AXTextArea", 1, true), "format reports the role")
T.ok(block:find("AXValue=string(11)", 1, true), "format reports value type and length")
T.ok(block:find("AXSelectedTextRange=loc=5 len=0", 1, true), "format reports the range")
T.ok(block:find("AXBoundsForRange=x=100 y=200 w=2 h=18", 1, true), "format reports the bounds")

-- A missing attribute reads as "absent", never as a Lua nil-concat crash
local absent = probe.format("Microsoft PowerPoint", facts({ value = ABSENT, range = ABSENT, rect = ABSENT }),
  "no-go", "no AXValue")
T.ok(absent:find("AXValue=absent", 1, true), "format reports absent value")
T.ok(absent:find("AXSelectedTextRange=absent", 1, true), "format reports absent range")
T.ok(absent:find("AXBoundsForRange=absent", 1, true), "format reports absent bounds")

-- Degenerate bounds are called out, since that is the estimated/full fork
local degen = probe.format("Obsidian", facts({ rect = { x = 0, y = 0, w = 0, h = 0 } }),
  "estimated", "why")
T.ok(degen:find("degenerate", 1, true), "format flags degenerate bounds")

T.finish("probe")
