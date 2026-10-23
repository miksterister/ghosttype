-- GhostType · caret.lua
-- Reads the focused text field's caret position and preceding text via
-- AXUIElement, and inserts accepted suggestions.
--
-- Insertion uses hs.eventtap.keyStrokes() rather than writing AXValue
-- directly. Writing AXValue only works reliably in apps built on standard
-- Cocoa text views; apps with custom text-rendering engines (Word,
-- PowerPoint, Electron/CodeMirror editors) mostly ignore it or desync the
-- cursor. Simulated keystrokes go through the same input path a human
-- typing would use, so it works (or fails) consistently with how the app
-- otherwise behaves — at the cost of being slightly slower and, in apps
-- with autocorrect, occasionally getting autocorrected same as real typing.

local M = {}

-- Secure field: AX marks password inputs with the AXSecureTextField subrole.
-- Never read or suggest in one — reading is a privacy leak and suggesting is
-- nonsensical.
function M.isSecureField(subrole)
  return subrole == "AXSecureTextField"
end

-- Slices the text before an AX caret. `value` is the field's full UTF-8 text;
-- `loc` is the 0-indexed UTF-16 code-unit caret offset AX reports. Lua strings
-- are UTF-8 bytes, so we walk code points and count UTF-16 units. This is exact
-- for accented BMP text and non-BMP characters such as emoji. Stale/out-of-range
-- offsets clamp to the whole string; insertion still goes through simulated
-- keystrokes rather than direct AXValue writes.
-- Returns the byte offset immediately after `utf16Loc` UTF-16 code units, or
-- nil if the value is invalid. AX caret locations are UTF-16 offsets, while Lua
-- strings are UTF-8 bytes.
local function byteEndForUtf16Loc(value, utf16Loc)
  if utf16Loc <= 0 then return 0 end
  if not (utf8 and utf8.codes) then return nil end

  local units = 0
  local lastEnd = 0
  for byteStart, codepoint in utf8.codes(value) do
    local width = codepoint > 0xFFFF and 2 or 1
    if units + width > utf16Loc then return lastEnd end
    units = units + width
    lastEnd = byteStart + #utf8.char(codepoint) - 1
    if units == utf16Loc then return lastEnd end
  end
  return #value -- stale/out-of-range loc clamps to the whole string
end

-- Suffix by Unicode codepoint count rather than bytes so maxPrefixChars never
-- slices a multibyte character in half before sending context to the model.
function M.suffixUtf8Chars(value, maxChars)
  if not value or value == "" then return value or "" end
  if not maxChars or maxChars <= 0 then return "" end
  if not (utf8 and utf8.codes) then return value:sub(math.max(1, #value - maxChars + 1)) end

  local starts = {}
  for byteStart in utf8.codes(value) do table.insert(starts, byteStart) end
  if #starts <= maxChars then return value end
  return value:sub(starts[#starts - maxChars + 1])
end

-- First `maxChars` Unicode codepoints, never bisecting a multibyte character.
-- Mirror of suffixUtf8Chars for the after-caret text sent as the FIM suffix.
function M.prefixUtf8Chars(value, maxChars)
  if not value or value == "" then return value or "" end
  if not maxChars or maxChars <= 0 then return "" end
  if not (utf8 and utf8.offset) then return value:sub(1, maxChars) end
  local byteEnd = utf8.offset(value, maxChars + 1)
  if not byteEnd then return value end  -- fewer than maxChars codepoints
  return value:sub(1, byteEnd - 1)
end

function M.prefixForCaret(value, loc)
  if type(value) ~= "string" then return "" end
  loc = tonumber(loc) or 0
  local ok, byteEnd = pcall(byteEndForUtf16Loc, value, loc)
  if ok and type(byteEnd) == "number" then
    return value:sub(1, byteEnd)
  end
  -- Fallback for a runtime without the utf8 lib: the old byte approximation.
  return value:sub(1, math.min(loc, #value))
end

-- Text AFTER the caret (the line's remainder + rest of the field), UTF-16→UTF-8
-- correct, mirroring prefixForCaret. Used for mid-line suppression and, later,
-- as the suffix for FIM prompting.
function M.afterForCaret(value, loc)
  if type(value) ~= "string" then return "" end
  loc = tonumber(loc) or 0
  local ok, byteEnd = pcall(byteEndForUtf16Loc, value, loc)
  if ok and type(byteEnd) == "number" then
    return value:sub(byteEnd + 1)
  end
  return value:sub(math.min(loc, #value) + 1)
end

-- Returns { element, prefix, rect } for the focused text field, or nil if
-- there's no focused text field, a non-empty selection (we only suggest at
-- a plain caret), or no usable bounds to anchor the overlay to.
--
-- The single rule for "is this a usable caret rect", shared by the
-- integer-range path and the text-marker path so the two cannot disagree.
--
-- HEIGHT is the validity signal, never width: a collapsed caret legitimately
-- has w = 0. Judging width was a real bug until 2026-09-18 — Notes reports
-- {x=251,y=132,w=0,h=18}, an exact caret, and we threw it away and estimated
-- instead, drawing the ghost tens of pixels from the cursor in a tier-1 app.
-- Chromium's placeholder {x=0,y=982,w=0,h=0} is still rejected: h = 0. (982 is
-- just the window's bottom edge, which is why it reads as a plausible y.)
--
-- An EMPTY field answers with the whole line box (w = field width) rather than
-- a caret; its left edge is where the caret sits, and overlay.show draws at
-- x + w, so a fat w would fling the ghost to the far right of the field.
-- Flatten anything wider than a caret. Returns a usable rect, or nil.
function M.normalizeCaretRect(rect)
  if type(rect) ~= "table" or type(rect.x) ~= "number" then return nil end
  if type(rect.h) ~= "number" or rect.h <= 0 then return nil end
  local w = rect.w or 0
  if w > 4 then w = 0 end -- line box, not a caret: the caret is its left edge
  return { x = rect.x, y = rect.y, w = w, h = rect.h }
end

-- Kept as the readable name at the call sites (and used by probe.lua), but
-- defined in terms of the normalizer so there is exactly one rule to change.
function M.isDegenerateRect(rect)
  return M.normalizeCaretRect(rect) == nil
end

-- Codepoints on the current line before the caret (chars since the last newline).
function M.currentColumn(prefix)
  if type(prefix) ~= "string" then return 0 end
  local line = prefix:match("[^\n]*$") or ""
  return utf8.len(line) or #line
end

-- Estimate a caret rect when AX geometry is degenerate: x from the element frame's
-- left edge + a left pad + column*charWidth; y from the (usually-correct) raw rect
-- y, else the frame top; h from the metric line height. Approximate by design.
function M.estimateRect(frame, rawRect, column, metrics)
  local m = metrics or {}
  local charWidth = m.charWidth or 8
  local lineHeight = m.lineHeight or 20
  local leftPad = m.leftPad or 4
  local fx = (type(frame) == "table" and frame.x) or 0
  local fy = (type(frame) == "table" and frame.y) or 0
  local y = (type(rawRect) == "table" and rawRect.y) or fy
  -- Chromium (Claude, Obsidian) fills degenerate rects with y = screen height,
  -- not the caret's y — trusting it drew the ghost one pixel below the screen.
  -- Keep rawRect.y only when it falls inside the element frame; otherwise clamp.
  local fh = (type(frame) == "table" and frame.h) or 0
  if fh > 0 then y = math.max(math.min(y, fy + fh - lineHeight), fy) end
  local x = fx + leftPad + (column or 0) * charWidth
  -- Soft-wrapped lines (CodeMirror paragraphs) report a column counted since
  -- the last hard newline, so x can march past the pane and the ghost text
  -- renders offscreen — "works until a certain sentence length". Clamp to the
  -- frame's right edge so it stays visible; x is approximate on wrapped lines.
  -- ponytail: clamp, not wrap-modeling — exact x on soft wraps is unknowable via AX.
  local fw = (type(frame) == "table" and frame.w) or 0
  if fw > 0 then x = math.min(x, fx + fw - 40) end
  return { x = x, y = y, w = 2, h = lineHeight }
end

-- WebKit web areas (Mail compose, some embedded web views) expose the caret
-- via text markers, not AXSelectedTextRange/AXValue — the value is empty and
-- the integer range is absent, so the standard path bails. Read through the
-- marker parameterized attributes instead (verified live against Mail
-- 2026-07-10): selection range → plain-caret check + caret bounds; doc
-- start/end markers → prefix and suffix strings.
local function webAreaContext(focused, maxPrefixChars, maxSuffixChars)
  local sel = focused:attributeValue("AXSelectedTextMarkerRange")
  if not sel then return nil end
  local ok, selStart, selEnd = pcall(function() return sel:startMarker(), sel:endMarker() end)
  if not ok or not selStart or not selEnd then return nil end

  local selLen = focused:parameterizedAttributeValue("AXLengthForTextMarkerRange", sel)
  if selLen ~= 0 then return nil end -- text is selected, not a plain caret — skip

  local docStart = focused:attributeValue("AXStartTextMarker")
  local docEnd   = focused:attributeValue("AXEndTextMarker")
  if not docStart or not docEnd then return nil end

  local preRange = focused:parameterizedAttributeValue("AXTextMarkerRangeForUnorderedTextMarkers", { docStart, selStart })
  local prefix = preRange and focused:parameterizedAttributeValue("AXStringForTextMarkerRange", preRange)
  if type(prefix) ~= "string" then return nil end
  local postRange = focused:parameterizedAttributeValue("AXTextMarkerRangeForUnorderedTextMarkers", { selEnd, docEnd })
  local afterCursor = postRange and focused:parameterizedAttributeValue("AXStringForTextMarkerRange", postRange)
  if type(afterCursor) ~= "string" then afterCursor = "" end

  local rect = focused:parameterizedAttributeValue("AXBoundsForTextMarkerRange", sel)
  if type(rect) ~= "table" or type(rect.x) ~= "number" then return nil end

  return {
    element = focused,
    prefix = M.suffixUtf8Chars(prefix, maxPrefixChars or 800),
    afterCursor = M.prefixUtf8Chars(afterCursor, maxSuffixChars or 200),
    rect = rect,
    estimated = false,
  }
end

function M.getFocusedContext(app, maxPrefixChars, maxSuffixChars, fallback)
  if not app then return nil end
  local ok, axApp = pcall(hs.axuielement.applicationElement, app)
  if not ok or not axApp then return nil end

  local focused = axApp:attributeValue("AXFocusedUIElement")
  if not focused then return nil end
  if M.isSecureField(focused:attributeValue("AXSubrole")) then return nil end

  local value = focused:attributeValue("AXValue")
  if type(value) ~= "string" then return nil end

  local range = focused:attributeValue("AXSelectedTextRange")
  if not range then
    -- No integer selection range: WebKit content (Mail compose) speaks text
    -- markers instead. pcall: marker userdata/methods only exist on WebKit.
    local okWeb, ctx = pcall(webAreaContext, focused, maxPrefixChars, maxSuffixChars)
    return okWeb and ctx or nil
  end
  local loc = range.loc or range.location
  local len = range.len or range.length
  if type(loc) ~= "number" or type(len) ~= "number" then return nil end
  if len ~= 0 then return nil end -- text is selected, not a plain caret — skip

  local prefix = M.prefixForCaret(value, loc)
  local afterCursor = M.prefixUtf8Chars(M.afterForCaret(value, loc), maxSuffixChars or 200)

  maxPrefixChars = maxPrefixChars or 800
  prefix = M.suffixUtf8Chars(prefix, maxPrefixChars)

  local rectOk, rect = pcall(function()
    return focused:parameterizedAttributeValue("AXBoundsForRange", { location = loc, length = 0 })
  end)
  if not rectOk or type(rect) ~= "table" then
    hs.printf("[GhostType] no caret bounds for focused element\n")
    return nil
  end

  local estimated = false
  local usable = M.normalizeCaretRect(rect)
  if usable then
    rect = usable
  else
    -- Chromium answers AXBoundsForRange with a placeholder but usually serves
    -- EXACT caret bounds over the WebKit text-marker protocol (it implements it
    -- for VoiceOver). Try that before estimating — when it works the ghost sits
    -- on the real caret, soft wraps and all. Probed 2026-09-18: Claude, Notion,
    -- Teams, AFFiNE and Anytype all expose markers AND an integer range, so the
    -- rescue has to be keyed on the rect being unusable, not on the range being
    -- absent. pcall: marker attributes only exist on web-content elements.
    local mOk, mRect = pcall(function()
      local sel = focused:attributeValue("AXSelectedTextMarkerRange")
      return sel and focused:parameterizedAttributeValue("AXBoundsForTextMarkerRange", sel)
    end)
    mRect = mOk and M.normalizeCaretRect(mRect) or nil
    if mRect then
      rect = mRect
    else
      if not fallback then
        hs.printf("[GhostType] degenerate caret bounds and no fallback metrics\n")
        return nil
      end
      local frameOk, frame = pcall(function() return focused:attributeValue("AXFrame") end)
      if not frameOk or type(frame) ~= "table" then return nil end
      rect = M.estimateRect(frame, rect, M.currentColumn(prefix), fallback)
      estimated = true
    end
  end

  return { element = focused, prefix = prefix, afterCursor = afterCursor, rect = rect, estimated = estimated }
end

-- Inserts `text` at the current cursor by simulating keystrokes.
function M.insertText(text)
  if not text or text == "" then return end
  hs.eventtap.keyStrokes(text)
end

return M
