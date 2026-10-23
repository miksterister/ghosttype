-- GhostType · spellcheck.lua
-- Grammar/spelling CHECK for the paragraph around the caret. It never edits on
-- its own: it lists what it thinks is wrong and you accept the ones you agree
-- with. LanguageTool's contract, not autocorrect.
--
-- The panel stays open across accepts. Take 2 of 5, or 3 of 8, in any order —
-- after each one the remaining offsets are re-based against the edit, so the
-- list stays live instead of going stale after the first change.
--
-- Deliberately hotkey-triggered rather than live-on-idle: the check costs a
-- model round trip per sentence (~300ms), and unrequested underlines appearing
-- while you type is the noise this design exists to avoid.

local M = {}

local canvas = nil
local modal = nil
local cfg, log = nil, nil
local state = { issues = {}, sel = 1, applied = 0, element = nil, paraStart = 1, text = "", pid = nil }
local appWatcher = nil

-- AX operations address the element we stored; synthetic keystrokes go to
-- whatever app is frontmost RIGHT NOW. If those two ever disagree we would type
-- one app's corrections into another — which is exactly what happened during
-- testing on 2026-08-24, when a panel left open in TextEdit had its keystrokes
-- land in Word. Every path that can type checks this first.
local function sameApp()
  local a = hs.application.frontmostApplication()
  return a ~= nil and state.pid ~= nil and a:pid() == state.pid
end

-- ── UTF-16 ↔ UTF-8 ↔ codepoint offsets ───────────────────────────────────────
-- Three coordinate systems meet here and mixing them silently corrupts text:
--   AX (AXSelectedTextRange, AXBoundsForRange) speaks UTF-16 code units
--   Lua strings are bytes
--   the server reports codepoint offsets (Python string indices)
-- All three agree for plain Latin text and diverge the moment an emoji appears.
local function utf16len(s)
  local n = 0
  for _, cp in utf8.codes(s) do n = n + (cp < 0x10000 and 1 or 2) end
  return n
end

-- byte index (1-based) of the character at codepoint offset `cp` (0-based)
local function cpToByte(s, cp)
  if cp <= 0 then return 1 end
  local n = 0
  for i in utf8.codes(s) do
    if n == cp then return i end
    n = n + 1
  end
  return #s + 1
end

-- byte index (1-based) of the character at UTF-16 offset `target` (0-based)
local function utf16ToByte(s, target)
  if target <= 0 then return 1 end
  local n = 0
  for i, c in utf8.codes(s) do
    if n >= target then return i end
    n = n + (c < 0x10000 and 1 or 2)
  end
  return #s + 1
end

-- ── Pure list surgery ────────────────────────────────────────────────────────
-- The block around the caret. We check a paragraph, not the document: one
-- request batches all its sentences, and offsets stay small and meaningful.
local function paragraphBounds(value, caretByte)
  local s = value:sub(1, caretByte - 1):find("\n[^\n]*$")
  local startB = s and (s + 1) or 1
  local e = value:find("\n", caretByte)
  local endB = e and (e - 1) or #value
  return startB, endB
end

-- The unit to check: a non-empty selection as-is (may span lines — the server
-- strips each line's markdown prefix itself), otherwise the paragraph around
-- the caret. AX ranges are UTF-16; the result is bytes.
local function unitBounds(value, locU16, lenU16)
  local caretByte = utf16ToByte(value, locU16)
  if (lenU16 or 0) > 0 then
    return caretByte, utf16ToByte(value, locU16 + lenU16) - 1
  end
  return paragraphBounds(value, caretByte)
end

-- The last `n` words before a span, so a fragment row ("late. → house; they
-- are late.") reads as part of its sentence instead of a riddle.
local function rowContext(text, startCp, n)
  local before = text:sub(1, cpToByte(text, startCp) - 1)
  local words = {}
  for w in before:gmatch("%S+") do words[#words + 1] = w end
  local out = {}
  for i = math.max(1, #words - n + 1), #words do out[#out + 1] = words[i] end
  return table.concat(out, " ")
end

-- Replace one span in `text` (codepoint offsets) and return the new text.
local function spliceText(text, startCp, endCp, replacement)
  return text:sub(1, cpToByte(text, startCp) - 1) .. replacement .. text:sub(cpToByte(text, endCp))
end

-- Drop issue `idx` and shift everything that starts after it by `delta`
-- codepoints. This is what lets the panel survive an accept: issues before the
-- edit are untouched, issues after it move by exactly the length change.
-- Overlapping issues are dropped rather than guessed at.
local function rebaseIssues(issues, idx, delta)
  local applied = issues[idx]
  local out = {}
  for i, iss in ipairs(issues) do
    if i ~= idx then
      if iss.start >= applied["end"] then
        out[#out + 1] = { start = iss.start + delta, ["end"] = iss["end"] + delta,
                          original = iss.original, suggestion = iss.suggestion }
      elseif iss["end"] <= applied.start then
        out[#out + 1] = iss
      end
      -- else: overlaps the span we just rewrote; its offsets are meaningless now
    end
  end
  return out
end

-- ── Panel ────────────────────────────────────────────────────────────────────
local function hide()
  if canvas then canvas:delete(); canvas = nil end
  if modal then modal:exit() end
  state.issues = {}
end

local function caretRect(element)
  local range = element:attributeValue("AXSelectedTextRange")
  local loc = range and (range.loc or range.location)
  if loc then
    local ok, r = pcall(function()
      return element:parameterizedAttributeValue("AXBoundsForRange", { location = loc, length = 0 })
    end)
    if ok and type(r) == "table" and r.x then return r end
  end
  local ok, frame = pcall(function() return element:attributeValue("AXFrame") end)
  if ok and type(frame) == "table" then return frame end
  local p = hs.mouse.absolutePosition()
  return { x = p.x, y = p.y, w = 0, h = 16 }
end

local function draw(rect)
  if canvas then canvas:delete(); canvas = nil end
  local issues = state.issues
  local fontSize = (cfg.fontSize or 14)
  local line = fontSize * 1.7
  local rows = math.min(#issues, 9)
  local w, h = 480, line * (rows + 2) + 18

  local screen = hs.screen.mainScreen():frame()
  local x = math.max(screen.x + 8, math.min(rect.x, screen.x + screen.w - w - 20))
  local y = rect.y + (rect.h or 16) + 6
  if y + h > screen.y + screen.h then y = math.max(screen.y + 8, rect.y - h - 6) end

  canvas = hs.canvas.new({ x = x, y = y, w = w, h = h })
  canvas:level(hs.drawing.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:appendElements({
    type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 8, yRadius = 8 },
    fillColor = { red = 0.11, green = 0.11, blue = 0.13, alpha = 0.96 },
  }, {
    type = "text",
    text = string.format("GhostType · %d left%s", #issues,
      state.applied > 0 and string.format("  ·  %d accepted", state.applied) or ""),
    textFont = cfg.fontName or ".AppleSystemUIFont", textSize = fontSize * 0.85,
    textColor = { red = 0.6, green = 0.6, blue = 0.65, alpha = 1 },
    frame = { x = 12, y = 9, w = w - 24, h = line },
  })

  for i = 1, rows do
    local iss = issues[i]
    local isSel = (i == state.sel)
    if isSel then
      canvas:appendElements({
        type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 5, yRadius = 5 },
        fillColor = { red = 0.24, green = 0.35, blue = 0.55, alpha = 0.55 },
        frame = { x = 7, y = 7 + line * i, w = w - 14, h = line },
      })
    end
    -- dimmed context words, then the span itself; one styled string per row
    local font  = { name = cfg.fontName or ".AppleSystemUIFont", size = fontSize }
    local white = { red = 0.95, green = 0.95, blue = 0.97, alpha = 1 }
    local dim   = { red = 0.55, green = 0.55, blue = 0.6, alpha = 1 }
    local row = hs.styledtext.new(string.format("%d   ", i), { font = font, color = white })
    local ctxWords = rowContext(state.text, iss.start, 3)
    if ctxWords ~= "" then
      row = row .. hs.styledtext.new("…" .. ctxWords .. " ", { font = font, color = dim })
    end
    row = row .. hs.styledtext.new(string.format("%s  →  %s", iss.original, iss.suggestion),
                                   { font = font, color = white })
    canvas:appendElements({
      type = "text", text = row, textLineBreak = "truncateTail",
      frame = { x = 14, y = 9 + line * i, w = w - 28, h = line },
    })
  end

  canvas:appendElements({
    type = "text",
    text = "[↑↓] move   [⏎] accept   [1-9] one   [x] skip   [a] all   [b] bigger model   [esc] done",
    textFont = cfg.fontName or ".AppleSystemUIFont", textSize = fontSize * 0.78,
    textColor = { red = 0.5, green = 0.5, blue = 0.55, alpha = 1 },
    frame = { x = 12, y = 10 + line * (rows + 1), w = w - 24, h = line },
  })
  canvas:show()
end

-- ── Applying ─────────────────────────────────────────────────────────────────
-- Select the span, then replace it. Two things this must not do:
--   1. Trust setAttributeValue("AXSelectedText", ...). Microsoft Word returns
--      SUCCESS and changes nothing — verified 2026-08-24. We compare AXValue
--      before and after and fall back to typing over the live selection.
--   2. Replace a span whose text is not what the checker saw. The panel stays
--      open across accepts, so the user may have typed in between; if the
--      selection does not match, we refuse rather than corrupt the sentence.
local function replaceSpan(element, iss)
  local value = element:attributeValue("AXValue")
  if type(value) ~= "string" then return false, "unreadable" end

  local sB = state.paraStart + cpToByte(state.text, iss.start) - 1
  local eB = state.paraStart + cpToByte(state.text, iss["end"]) - 1
  local loc = utf16len(value:sub(1, sB - 1))
  local len = utf16len(value:sub(sB, eB - 1))

  local okRange = pcall(function()
    element:setAttributeValue("AXSelectedTextRange", { location = loc, length = len })
  end)
  if not okRange then return false, "cannot select" end

  local sel = element:attributeValue("AXSelectedText")
  if type(sel) == "string" and sel ~= iss.original then
    return false, "text moved"
  end

  local before = element:attributeValue("AXValue")
  pcall(function() element:setAttributeValue("AXSelectedText", iss.suggestion) end)

  -- Poll rather than read once. An app that DID apply the edit may not have
  -- refreshed AXValue yet, and concluding "it failed" from a stale read would
  -- type the replacement a second time -> "It\'sIt\'s". 150ms of patience is
  -- cheaper than a double-applied edit.
  local applied = false
  for _ = 1, 6 do
    hs.timer.usleep(25000)
    local v = element:attributeValue("AXValue")
    if type(v) == "string" and v ~= before then applied = true break end
  end

  if not applied then
    if not sameApp() then return false, "focus changed" end
    -- Silent no-op (Word returns success and changes nothing). The span is
    -- still selected, so typing replaces it.
    --
    -- The modal MUST be off while we type: its 1-9 / a / x bindings are Carbon
    -- hotkeys and fire on synthetic events too, so replacing a word with
    -- "already" would trigger acceptAll on the "a".
    if modal then modal:exit() end
    hs.eventtap.keyStrokes(iss.suggestion)
    if modal then modal:enter() end
  end
  return true
end

local function finish(msg)
  local n = state.applied
  hide()
  if msg then hs.alert.show(msg)
  elseif n > 0 then hs.alert.show(string.format("GhostType: %d change%s applied", n, n == 1 and "" or "s")) end
end

local function acceptIndex(i)
  local iss = state.issues[i]
  if not iss then return end
  if not sameApp() then finish("GhostType: focus changed — re-run the check") return end
  local ok, why = replaceSpan(state.element, iss)
  if not ok then
    finish("GhostType: " .. (why or "could not apply") .. " — re-run the check")
    return
  end
  state.applied = state.applied + 1
  if log then log.write({ app = state.appName, outcome = "spell-accept", original = iss.original, suggestion = iss.suggestion }) end
  local delta = utf8.len(iss.suggestion) - utf8.len(iss.original)
  state.text = spliceText(state.text, iss.start, iss["end"], iss.suggestion)
  state.issues = rebaseIssues(state.issues, i, delta)
  if #state.issues == 0 then finish() return end
  state.sel = math.min(state.sel, #state.issues)
  draw(caretRect(state.element))
end

local function skipIndex(i)
  local iss = state.issues[i]
  if iss and log then log.write({ app = state.appName, outcome = "spell-skip", original = iss.original, suggestion = iss.suggestion }) end
  table.remove(state.issues, i)
  if #state.issues == 0 then finish() return end
  state.sel = math.min(state.sel, #state.issues)
  draw(caretRect(state.element))
end

local function acceptAll()
  if not sameApp() then finish("GhostType: focus changed — re-run the check") return end
  -- Right-to-left: each edit then lies after the ones still to come, so their
  -- offsets never move. Cheaper and safer than re-basing on every step.
  local order = {}
  for i = 1, #state.issues do order[i] = i end
  table.sort(order, function(a, b) return state.issues[a].start > state.issues[b].start end)
  for _, i in ipairs(order) do
    local iss = state.issues[i]
    local ok = replaceSpan(state.element, iss)
    if ok then
      state.applied = state.applied + 1
      if log then log.write({ app = state.appName, outcome = "spell-accept", original = iss.original, suggestion = iss.suggestion }) end
    end
  end
  finish()
end

local function move(d)
  if #state.issues == 0 then return end
  state.sel = ((state.sel - 1 + d) % #state.issues) + 1  -- wraps, so you can loop
  draw(caretRect(state.element))
end

-- ── Entry point ──────────────────────────────────────────────────────────────
-- opts.model: send the paragraph through a different (bigger) model — the
-- second-opinion path. Everything else is identical, including re-reading the
-- field, so accepts made from the fast pass are already in the text it sees.
function M.check(opts)
  local model = opts and opts.model or nil
  hide()
  local app = hs.application.frontmostApplication()
  if not app then return end
  local okApp, axApp = pcall(hs.axuielement.applicationElement, app)
  if not okApp or not axApp then return end
  local element = axApp:attributeValue("AXFocusedUIElement")
  if not element then hs.alert.show("GhostType: no text field") return end

  local value = element:attributeValue("AXValue")
  if type(value) ~= "string" or value == "" then
    hs.alert.show("GhostType: can't read this field")
    return
  end

  local range = element:attributeValue("AXSelectedTextRange")
  local locU16 = range and (range.loc or range.location) or 0
  local lenU16 = range and (range.len or range.length) or 0
  local pStart, pEnd = unitBounds(value, locU16, lenU16)
  local text = value:sub(pStart, pEnd)
  local cap = cfg.spellMaxChars or 4000
  if #text > cap then text = text:sub(1, cap) end
  if text:match("^%s*$") then hs.alert.show("GhostType: nothing to check") return end

  state.element, state.paraStart, state.text = element, pStart, text
  state.pid, state.appName = app:pid(), app:name()
  -- One line per run so a "no issues" verdict is diagnosable afterwards: which
  -- app, which AX role, how many chars were actually read around the caret.
  local entry = { app = app:name(), outcome = "check", chars = utf8.len(text) or #text,
                  ctx = text, role = element:attributeValue("AXRole") or "?" }
  state.issues, state.sel, state.applied = {}, 1, 0
  local rect = caretRect(element)

  if model then hs.alert.show("GhostType: checking with " .. model .. "…", 1.5) end
  hs.http.asyncPost(
    (cfg.spellServerUrl or "http://127.0.0.1:8791") .. "/check",
    hs.json.encode({ text = text, model = model }),
    { ["Content-Type"] = "application/json" },
    function(status, body)
      if status ~= 200 then
        hs.alert.show("GhostType: spellcheck server not reachable")
        entry.status = status
        if log then log.write(entry) end
        return
      end
      local ok, data = pcall(hs.json.decode, body)
      if not ok or not data then return end
      state.issues = data.issues or {}
      entry.issues, entry.skipped = #state.issues, #(data.skipped or {})
      if log then log.write(entry) end
      if #state.issues == 0 then
        hs.alert.show(#(data.skipped or {}) > 0 and "GhostType: skipped (not English)"
                                                 or "GhostType: no issues")
        return
      end
      state.sel = 1
      draw(rect)
      if modal then modal:enter() end
    end)
end

function M.setup(config, logger)
  cfg, log = config, logger
  -- A live modal binds 1-9 / a / x / arrows GLOBALLY. Leaving it up after the
  -- user switches away would swallow their keystrokes in another app, so the
  -- panel dies with the app switch.
  appWatcher = hs.application.watcher.new(function(_, event)
    if event == hs.application.watcher.activated and #state.issues > 0 and not sameApp() then
      hide()
    end
  end)
  appWatcher:start()
  M.appWatcher = appWatcher  -- root it; a collected watcher stops firing
  modal = hs.hotkey.modal.new()
  for i = 1, 9 do modal:bind({}, tostring(i), function() acceptIndex(i) end) end
  modal:bind({}, "up",     function() move(-1) end)
  modal:bind({}, "down",   function() move(1) end)
  modal:bind({}, "return", function() acceptIndex(state.sel) end)
  modal:bind({}, "x",      function() skipIndex(state.sel) end)
  modal:bind({}, "a",      acceptAll)
  modal:bind({}, "b",      function() M.check({ model = cfg.spellDeepModel }) end)
  modal:bind({}, "escape", function() finish() end)
  return M
end

M.hide = hide

-- Exposed so the accept path is checkable without synthesising a keystroke —
-- same reasoning as init.lua's M.setEnabled. `hs -c 'require("ghosttype.spellcheck").accept(1)'`
M.accept = function(i) acceptIndex(i) end
M.acceptAll = acceptAll
M.issues = function() return state.issues end

-- Exported for test_spellcheck.lua. The offset conversions and the re-basing
-- are the only places this module can silently corrupt text, so they get a
-- runnable check — same reasoning as caret.lua exporting prefixForCaret.
M._utf16len = utf16len
M._cpToByte = cpToByte
M._utf16ToByte = utf16ToByte
M._paragraphBounds = paragraphBounds
M._unitBounds = unitBounds
M._rowContext = rowContext
M._spliceText = spliceText
M._rebaseIssues = rebaseIssues

return M
