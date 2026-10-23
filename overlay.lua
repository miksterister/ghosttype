-- GhostType · overlay.lua
-- Draws the ghost-text suggestion as a floating hs.canvas positioned at the
-- caret's screen bounds. Non-interactive (mouse events pass through).
--
-- Known limitation: the overlay approximates the host app's font/size via
-- config rather than reading it from AX (most apps don't expose it), so
-- alignment is close-but-not-pixel-perfect. Good enough to read as an
-- inline suggestion; not meant to be indistinguishable from real text.

local M = {}

local canvas = nil

function M.hide()
  if canvas then
    canvas:delete()
    canvas = nil
  end
end

-- rect: {x, y, w, h} caret bounds in screen coordinates (as returned by
-- AXBoundsForRange). text: the suggestion to render just after the caret.
function M.show(rect, text, cfg)
  M.hide()
  if not text or text == "" then return end

  local fontSize = cfg.fontSize or 14
  local avgCharW = fontSize * 0.56
  local w = math.min(900, math.max(20, #text * avgCharW + 12))
  local h = math.max(rect.h or 0, fontSize * 1.4)

  local frame = { x = rect.x + (rect.w or 0), y = rect.y - (h - (rect.h or h)) / 2, w = w, h = h }

  canvas = hs.canvas.new(frame)
  canvas:level(hs.drawing.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:mouseCallback(nil) -- click-through
  canvas:appendElements({
    type = "text",
    text = text,
    textFont = cfg.fontName or ".AppleSystemUIFont",
    textSize = fontSize,
    textColor = cfg.ghostColor or { red = 0.55, green = 0.55, blue = 0.58, alpha = 0.85 },
    textLineBreak = "clip",
    frame = { x = 0, y = 0, w = w, h = h },
  })
  canvas:show()
end

return M
