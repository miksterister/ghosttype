package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local menubar = require("menubar")

-- titleFor: bright glyph only when enabled AND server reachable
T.eq(menubar.titleFor(true, true), "G", "title active")
T.eq(menubar.titleFor(false, true), "◌", "title off dims")
T.eq(menubar.titleFor(true, false), "◌", "title server-down dims")

-- tally: "shown" bumps shown, anything else bumps suppressed
menubar.counts = { shown = 0, reused = 0, suppressed = 0 }
menubar.tally("shown")
menubar.tally("shown")
menubar.tally("reused")
menubar.tally("suppress")
T.eq(menubar.counts.shown, 2, "tally shown")
T.eq(menubar.counts.reused, 1, "tally reused")
T.eq(menubar.counts.suppressed, 1, "tally suppressed")

-- sessionLabel: renders the current counts (reused defaults to 0 when absent)
T.eq(menubar.sessionLabel({ shown = 3, suppressed = 1 }),
     "This session: 3 shown · 0 reused · 1 suppressed", "session label")
-- sessionLabel: defaults to module counts
T.eq(menubar.sessionLabel(), "This session: 2 shown · 1 reused · 1 suppressed", "session label default")

-- obsidianLabel: /stats payload rendered; nil (server unreachable) degrades
T.eq(menubar.obsidianLabel({ shown = 4, accepted = 2, dismissed = 1 }),
     "Obsidian: 4 shown · 2 accepted · 1 dismissed", "obsidian label")
T.eq(menubar.obsidianLabel({}), "Obsidian: 0 shown · 0 accepted · 0 dismissed", "obsidian label empty stats")
T.eq(menubar.obsidianLabel(nil), "Obsidian: no data (server unreachable)", "obsidian label server down")

-- menuItems: pure menu construction; Settings… present and wired
local sentinel = function() end
local items = menubar.menuItems(
  { enabled = true, serverUp = true, handlers = { onSettings = sentinel } }, nil)
local found = nil
for _, it in ipairs(items) do
  if it.title == "Settings…" then found = it end
end
T.eq(found ~= nil, true, "Settings… item present")
T.eq(found.fn, sentinel, "Settings… dispatches onSettings")
T.eq(items[1].title, "● GhostType: on", "toggle row first")

-- The probe log needs a way out of the menubar, or the detail blocks are
-- written somewhere nobody ever looks.
local probeItem = nil
local probeSentinel = function() end
local items2 = menubar.menuItems(
  { enabled = true, serverUp = true, handlers = { onOpenProbeLog = probeSentinel } }, nil)
for _, it in ipairs(items2) do
  if it.title == "Open probe log" then probeItem = it end
end
T.eq(probeItem ~= nil, true, "Open probe log item present")
T.eq(probeItem.fn, probeSentinel, "Open probe log dispatches onOpenProbeLog")

T.finish("menubar")
