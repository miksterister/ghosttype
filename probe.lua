-- GhostType · probe.lua
-- "Will GhostType work in this app?" — answered by measurement instead of guesswork.
--
-- Press the probe hotkey with the caret in any text field and this reports what
-- that field's AX interface actually exposes, plus a verdict in the same terms
-- caret.getFocusedContext uses to decide whether to bail. Adding an app becomes
-- a ten-second check rather than a guess; this is the cheap answer to the
-- "it's not one hard problem, it's fifty app-specific ones" tail in the README.
--
-- The verdict predicates are caret.lua's own (isSecureField / isDegenerateRect),
-- deliberately NOT re-derived here: a probe that drifts from the live path would
-- confidently report "works" on a field getFocusedContext silently gives up on.

-- caret.lua is host-free at load (every hs.* call is inside a function), so the
-- same module serves the Hammerspoon runtime and the host-free unit tests; only
-- the module path differs between them.
local okCaret, caret = pcall(require, "ghosttype.caret")
if not okCaret then caret = require("caret") end

local M = {}

M.LOG_PATH = os.getenv("HOME") .. "/Library/Logs/ghosttype/probe.log"

-- ── Pure verdict logic (host-free, unit-tested) ──────────────────────────────

-- Classifies a gathered fact table into one of five outcomes. The branch order
-- deliberately mirrors caret.getFocusedContext:
--   full      — value + caret range + usable bounds; the fast path
--   estimated — value + range but degenerate geometry; needs fallback metrics
--   markers   — no integer range, but the WebKit text-marker path is available
--   retry     — a live selection; the prober's own doing, not an app limitation
--   no-go     — the live path would return nil here; GhostType cannot work
-- Returns verdict, reason.
function M.verdict(f)
  f = f or {}
  if not f.hasElement then return "no-go", "no focused UI element" end
  if f.secure then return "no-go", "secure text field (never read)" end
  if type(f.value) ~= "string" then return "no-go", "no AXValue" end

  if not f.range then
    if f.markers then return "markers", "no AXSelectedTextRange; AX text markers present" end
    return "no-go", "no AXSelectedTextRange and no text markers"
  end

  -- A selection is transient state, not a capability limit. Calling it no-go
  -- would libel an app that works perfectly well with a plain caret.
  if (f.range.len or 0) ~= 0 then
    return "retry", "text is selected — place a plain caret and probe again"
  end

  if not f.rect then return "no-go", "no AXBoundsForRange at the caret" end
  if not caret.isDegenerateRect(f.rect) then
    return "full", "AXValue + AXSelectedTextRange + usable AXBoundsForRange"
  end
  -- An unusable rect is not the end of the road: getFocusedContext falls back to
  -- the text-marker protocol before it estimates, and Chromium serves exact
  -- caret bounds there. Reporting "estimated" for an app that markers rescue
  -- would understate it — and drift from what the live path actually does.
  if f.markers then
    return "markers", "AXBoundsForRange unusable; exact bounds via AX text markers"
  end
  return "estimated", "AXBoundsForRange unusable and no text markers; position estimated"
end

-- The one line shown in the alert, readable without leaving the app under test.
-- The AX role rides along because the verdict alone can mislead: a focused
-- AXGroup with an empty AXValue probes "estimated" (the live path would proceed
-- too, then bail on minPrefixChars) while not being a text control at all.
-- Seen live in Arc. Judging an app needs the role, not just the verdict.
function M.summary(appName, verdict, reason, role)
  local line = string.format("%s → %s (%s)", appName or "?", (verdict or "?"):upper(), reason or "")
  if role and role ~= "" then line = line .. " [" .. role .. "]" end
  return line
end

local function describeValue(v)
  if type(v) ~= "string" then return "absent" end
  return string.format("string(%d)", (utf8 and utf8.len and utf8.len(v)) or #v)
end

local function describeRange(r)
  if type(r) ~= "table" then return "absent" end
  return string.format("loc=%s len=%s", tostring(r.loc), tostring(r.len))
end

local function describeRect(r)
  if type(r) ~= "table" then return "absent" end
  local s = string.format("x=%s y=%s w=%s h=%s",
    tostring(r.x), tostring(r.y), tostring(r.w), tostring(r.h))
  if caret.isDegenerateRect(r) then s = s .. " (degenerate)" end
  return s
end

-- The detail block appended to the probe log — one record per probe, so several
-- apps can be compared side by side afterwards.
function M.format(appName, f, verdict, reason)
  f = f or {}
  return table.concat({
    string.format("app=%s verdict=%s reason=%s", appName or "?", verdict or "?", reason or ""),
    string.format("  AXRole=%s AXSubrole=%s secure=%s",
      tostring(f.role or "absent"), tostring(f.subrole or "absent"), tostring(f.secure == true)),
    string.format("  AXValue=%s", describeValue(f.value)),
    string.format("  AXSelectedTextRange=%s", describeRange(f.range)),
    string.format("  AXBoundsForRange=%s", describeRect(f.rect)),
    string.format("  AXFrame=%s", describeRect(f.frame)),
    string.format("  textMarkers=%s", tostring(f.markers == true)),
  }, "\n")
end

-- ── Host side: gather, report ────────────────────────────────────────────────

-- Reads the frontmost app's focused element. Every AX call is pcall-wrapped:
-- probing an app with a hostile or half-built accessibility tree must produce a
-- verdict, not a Hammerspoon traceback.
function M.gather(app)
  local f = { hasElement = false }
  if not app then return f end

  local okApp, axApp = pcall(hs.axuielement.applicationElement, app)
  if not okApp or not axApp then return f end

  local okFocus, focused = pcall(function() return axApp:attributeValue("AXFocusedUIElement") end)
  if not okFocus or not focused then return f end
  f.hasElement = true

  local function attr(name)
    local ok, v = pcall(function() return focused:attributeValue(name) end)
    return ok and v or nil
  end

  f.role    = attr("AXRole")
  f.subrole = attr("AXSubrole")
  f.secure  = caret.isSecureField(f.subrole)
  f.value   = attr("AXValue")
  f.frame   = attr("AXFrame")
  f.markers = attr("AXSelectedTextMarkerRange") ~= nil

  local range = attr("AXSelectedTextRange")
  if range then
    -- AX reports loc/len under either spelling depending on the bridge; caret.lua
    -- accepts both, so the probe must normalize the same way.
    f.range = { loc = range.loc or range.location, len = range.len or range.length }
    if type(f.range.loc) == "number" and (f.range.len or 0) == 0 then
      local okRect, rect = pcall(function()
        return focused:parameterizedAttributeValue("AXBoundsForRange",
          { location = f.range.loc, length = 0 })
      end)
      if okRect and type(rect) == "table" then f.rect = rect end
    end
  end

  return f
end

local function append(block)
  local dir = M.LOG_PATH:match("(.+)/[^/]+$")
  if dir then os.execute('mkdir -p "' .. dir .. '"') end
  local fh = io.open(M.LOG_PATH, "a")
  if fh then
    fh:write(os.date("%Y-%m-%d %H:%M:%S "), block, "\n\n")
    fh:close()
  end
end

-- Probe the frontmost app: alert the verdict, append the detail block.
-- Deliberately does not consult config.apps — the whole point is to answer
-- "would this work?" for apps that are not enabled, or not listed at all.
function M.run()
  local app = hs.application.frontmostApplication()
  local appName = app and app:name() or "?"
  local f = M.gather(app)
  local verdict, reason = M.verdict(f)
  append(M.format(appName, f, verdict, reason))
  hs.alert.show(M.summary(appName, verdict, reason, f.role), { textSize = 15 }, 4)
  return verdict, reason
end

return M
