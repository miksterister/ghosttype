-- GhostType · menubar.lua
-- Native hs.menubar status item: an at-a-glance on/off + server-state glyph, and
-- a dropdown with toggle / open-log / reload plus a live session tally. Pure
-- presentation helpers (titleFor / sessionLabel / tally) are host-free and
-- unit-tested; the hs.menubar object is created host-side (setup) and exercised
-- by the live test. No hs.* call happens at module load, so it requires cleanly
-- under the host-free test stub.

local M = {}

-- ── Pure state / presentation (host-free, unit-tested) ───────────────────────
M.counts = { shown = 0, reused = 0, suppressed = 0 }

function M.tally(kind)
  if kind == "shown" then
    M.counts.shown = M.counts.shown + 1
  elseif kind == "reused" then
    M.counts.reused = M.counts.reused + 1
  else
    M.counts.suppressed = M.counts.suppressed + 1
  end
end

function M.sessionLabel(counts)
  counts = counts or M.counts
  return string.format("This session: %d shown · %d reused · %d suppressed",
    counts.shown, counts.reused or 0, counts.suppressed)
end

-- Obsidian's outcomes live server-side (the plugin POSTs them to /event);
-- format the /stats payload, or a fallback line when the server is unreachable.
function M.obsidianLabel(stats)
  if type(stats) ~= "table" then return "Obsidian: no data (server unreachable)" end
  return string.format("Obsidian: %d shown · %d accepted · %d dismissed",
    stats.shown or 0, stats.accepted or 0, stats.dismissed or 0)
end

-- Glyph reflects state without opening the menu: "G" when active, dimmed "◌"
-- when GhostType is off or the completion server is unreachable.
function M.titleFor(enabled, serverUp)
  if not enabled or not serverUp then return "◌" end
  return "G"
end

-- Pure menu construction: state -> hs.menubar menu table. Kept host-free so
-- the item list (and its handler wiring) is unit-testable.
-- st = { enabled, serverUp, handlers }; obsidianStats may be nil.
function M.menuItems(st, obsidianStats)
  local items = {
    { title = (st.enabled and "● GhostType: on" or "○ GhostType: off"),
      fn = st.handlers.onToggle },
    { title = (st.serverUp and "Server: reachable" or "Server: unreachable"),
      disabled = true },
    { title = M.sessionLabel(), disabled = true },
    { title = M.obsidianLabel(obsidianStats), disabled = true },
    { title = "-" },
    { title = "Settings…", fn = st.handlers.onSettings },
    { title = "Open prediction log", fn = st.handlers.onOpenLog },
    { title = "Open probe log", fn = st.handlers.onOpenProbeLog },
    { title = "Reload GhostType", fn = st.handlers.onReload },
  }
  return items
end

-- ── Host-side (hs.menubar) ───────────────────────────────────────────────────
local bar = nil
local st = { enabled = true, serverUp = true, handlers = {} }

local function refresh()
  if bar then bar:setTitle(M.titleFor(st.enabled, st.serverUp)) end
end

-- Menu-open-time fetch of the plugin tally — no polling; the server is local
-- so the synchronous call is a few ms (connection-refused when down is fast).
local function obsidianStats()
  if not st.statsUrl then return nil end
  local ok, status, body = pcall(hs.http.get, st.statsUrl .. "/stats", nil)
  if not ok or status ~= 200 or type(body) ~= "string" then return nil end
  local okJson, data = pcall(hs.json.decode, body)
  return okJson and data or nil
end

-- handlers = { onToggle = fn, onOpenLog = fn, onReload = fn, onSettings = fn,
--              statsUrl = serverUrl }
function M.setup(handlers)
  st.handlers = handlers or {}
  st.statsUrl = st.handlers.statsUrl
  bar = hs.menubar.new()
  if not bar then return nil end
  bar:setMenu(function()
    return M.menuItems(st, obsidianStats())
  end)
  refresh()
  return bar
end

function M.setEnabled(v) st.enabled = v; refresh() end
function M.setServerUp(v) st.serverUp = v; refresh() end
function M.destroy() if bar then bar:delete(); bar = nil end end

return M
