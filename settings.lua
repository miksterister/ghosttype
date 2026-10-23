-- GhostType · settings.lua
-- The settings window: pure merge/validation half (host-free, unit-tested)
-- plus the hs.webview host half (M.build / M.open, added below the pure
-- section). No hs.* call happens at module load or inside the pure functions,
-- so this requires cleanly under tests/hs_stub.lua.

local M = {}

-- ── Pure: validation + merge (host-free, unit-tested) ────────────────────────

local CLAMP = {
  idleMs             = { min = 100, max = 600 },
  maxTokens          = { min = 4,   max = 20 },
  fontSize           = { min = 8,   max = 36 },
  requestTimeoutSec  = { min = 1,   max = 10 },
  fallbackCharWidth  = { min = 2,   max = 30 },
  fallbackLineHeight = { min = 8,   max = 60 },
  fallbackLeftPad    = { min = 0,   max = 50 },
}

-- The UI may edit pattern lists only on these apps (tier-2 browsers).
local BROWSERS = { ["Arc"] = true, ["Google Chrome"] = true,
                   ["Safari"] = true, ["Vivaldi"] = true }

local MODS_ALLOWED = { cmd = true, alt = true, ctrl = true, shift = true }

-- The JS recorder ships e.key.toLowerCase() verbatim ("enter", " ",
-- "backspace"), which hs.keycodes / hs.hotkey.bind does not understand —
-- translate the JS names hs.hotkey.bind actually needs, then allowlist the
-- remaining multi-char names (function keys handled separately via pattern).
local KEY_ALIAS = { enter = "return", [" "] = "space", backspace = "delete" }
local KEY_ALLOWED = { ["return"] = true, space = true, tab = true, delete = true,
                      forwarddelete = true, escape = true, home = true, ["end"] = true,
                      pageup = true, pagedown = true, help = true }

local function clamped(v, c)
  local n = tonumber(v)
  if not n then return nil end
  if n < c.min then return c.min end
  if n > c.max then return c.max end
  return n
end

local function isStringList(t)
  if type(t) ~= "table" then return false end
  local count = 0
  for k, v in pairs(t) do
    if type(k) ~= "number" or type(v) ~= "string" then return false end
    count = count + 1
  end
  return count == #t
end

-- Normalized { mods, key } or nil when unusable as a global toggle:
-- mods allowlisted (unknown dropped), key lowercased and non-empty,
-- arrows and modifier-less combos rejected.
function M.validateHotkey(hk)
  if type(hk) ~= "table" or type(hk.key) ~= "string" or hk.key == "" then return nil end
  local key = hk.key:lower()
  if key:match("^arrow") or key == "left" or key == "right"
     or key == "up" or key == "down" then return nil end
  key = KEY_ALIAS[key] or key
  if #key > 1 and not KEY_ALLOWED[key] and not key:match("^f%d%d?$") then return nil end
  if type(hk.mods) ~= "table" then return nil end
  local mods = {}
  for _, m in ipairs(hk.mods) do
    local ml = tostring(m):lower()
    if MODS_ALLOWED[ml] then mods[#mods + 1] = ml end
  end
  if #mods == 0 then return nil end
  return { mods = mods, key = key }
end

-- "#rrggbb" + alpha -> {red, green, blue, alpha} floats, or nil if malformed.
function M.parseColor(hex, alpha)
  if type(hex) ~= "string" then return nil end
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then return nil end
  local a = tonumber(alpha)
  if not a then return nil end
  if a < 0 then a = 0 elseif a > 1 then a = 1 end
  return { red = tonumber(r, 16) / 255, green = tonumber(g, 16) / 255,
           blue = tonumber(b, 16) / 255, alpha = a }
end

-- Merges the UI payload into config (mutating and returning it) plus a list
-- of human-readable warnings. Copies ONLY the keys the UI owns — unknown or
-- injected keys are ignored, config keys the UI doesn't carry (e.g. `model`)
-- are untouched. Deliberately stricter than TextLens's whole-object replace.
function M.applySettings(config, incoming)
  local warnings = {}
  if type(incoming) ~= "table" then return config, { "invalid settings payload" } end

  if incoming.enabled ~= nil then config.enabled = incoming.enabled == true end

  if incoming.toggleHotkey ~= nil then
    local hk = M.validateHotkey(incoming.toggleHotkey)
    if hk then config.toggleHotkey = hk
    else warnings[#warnings + 1] = "invalid hotkey — kept the old one" end
  end

  for key, c in pairs(CLAMP) do
    if incoming[key] ~= nil then
      local v = clamped(incoming[key], c)
      if v ~= nil then config[key] = v end
    end
  end

  if type(incoming.fontName) == "string" and incoming.fontName ~= "" then
    config.fontName = incoming.fontName
  end
  if incoming.serverUrl ~= nil then
    if type(incoming.serverUrl) == "string" and incoming.serverUrl:match("^https?://") then
      config.serverUrl = incoming.serverUrl
    end
  end

  -- Prefix window is a pair: both positive and min <= max, or keep both.
  local minP, maxP = tonumber(incoming.minPrefixChars), tonumber(incoming.maxPrefixChars)
  if minP and minP > 0 and maxP and maxP > 0 then
    if minP <= maxP then
      config.minPrefixChars, config.maxPrefixChars = minP, maxP
    else
      warnings[#warnings + 1] = "min prefix > max prefix — kept old values"
    end
  end
  local sfx = tonumber(incoming.maxSuffixChars)
  if sfx and sfx > 0 then config.maxSuffixChars = sfx end

  if incoming.ghostHex ~= nil or incoming.ghostAlpha ~= nil then
    local col = M.parseColor(incoming.ghostHex, incoming.ghostAlpha)
    if col then config.ghostColor = col
    else warnings[#warnings + 1] = "invalid ghost color — kept the old one" end
  end

  -- Apps: only known app names; UI owns `enabled` everywhere and the pattern
  -- lists on browsers. `tier` (and anything else) never comes from the UI —
  -- it's a display badge, not an input.
  if type(incoming.apps) == "table" and type(config.apps) == "table" then
    for name, inc in pairs(incoming.apps) do
      local existing = config.apps[name]
      if existing and type(inc) == "table" then
        if inc.enabled ~= nil then existing.enabled = inc.enabled == true end
        if BROWSERS[name] then
          if inc.sitePatterns ~= nil and isStringList(inc.sitePatterns) then
            existing.sitePatterns = inc.sitePatterns
          end
          if inc.titlePatterns ~= nil and isStringList(inc.titlePatterns) then
            existing.titlePatterns = inc.titlePatterns
          end
        end
      end
    end
  end

  -- maxTokens is draggable in the UI; maxWords is not. Set the budget at or
  -- below 2×maxWords and it fires before the word cap can bind, so suggestions
  -- end wherever the budget ran out — mid-word — and the cap looks broken
  -- rather than the budget. Warn instead of silently clamping: it is the user's
  -- knob, they just need to know it stopped doing what it says.
  local words = tonumber(config.maxWords) or 4
  local tokens = tonumber(config.maxTokens) or 0
  if tokens > 0 and tokens < 2 * words then
    warnings[#warnings + 1] = string.format(
      "maxTokens %d is too low for maxWords %d — suggestions will end mid-word; use %d+",
      tokens, words, 2 * words)
  end

  return config, warnings
end

-- ── Host side (hs.webview) — no unit tests; exercised live ───────────────────

local view = nil

local function escapeJS(s)
  return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("</", "<\\/")
end

-- Ask the server what it actually loaded (the `model` config key is decorative).
-- Synchronous, but local and only on Settings open; down → fast refusal.
local function serverModel(config)
  local ok, status, body = pcall(hs.http.get, config.serverUrl .. "/model", nil)
  if ok and status == 200 then
    local okJson, data = pcall(hs.json.decode, body)
    if okJson and type(data) == "table" and data.model then return data.model end
  end
  return "unknown (server not running)"
end

function M.build(config)
  local path = hs.configdir .. "/ghosttype/assets/settings.html"
  local f = io.open(path, "r")
  if not f then
    hs.notify.new({ title = "GhostType",
      informativeText = "Missing asset: ghosttype/assets/settings.html" }):send()
    return "<html><body>settings.html not found</body></html>"
  end
  local html = f:read("*a"); f:close()
  html = html:gsub("__CFGJSON__", function() return escapeJS(hs.json.encode(config)) end, 1)
  html = html:gsub("__MODEL__", function() return serverModel(config) end, 1)
  return html
end

-- Opens (or replaces) the settings window. Mutates `config` in place on save
-- via applySettings, then calls callbacks.onSaved(warnings); the caller owns
-- persistence and re-registration side effects.
function M.open(config, callbacks)
  if view then view:delete(); view = nil end

  local uc = hs.webview.usercontent.new("ghosttype_settings")
  uc:setCallback(function(msg)
    local body = tostring(msg.body or "")
    local cmd, data = body:match("^([^:]+)::(.*)$")
    if not cmd then cmd = body end
    if cmd == "close" then
      if view then view:delete(); view = nil end
    elseif cmd == "setEnabled" and data then
      -- The header master switch applies INSTANTLY (not on Save) through the
      -- same path as the menubar/hotkey toggle, so all three stay in sync.
      -- `enabled` is deliberately absent from the save payload: a stale open
      -- window must never clobber a toggle made elsewhere while it sat open.
      if callbacks and callbacks.onSetEnabled then callbacks.onSetEnabled(data == "true") end
    elseif cmd == "move" and data then
      local dx, dy = data:match("^(%-?%d+),(%-?%d+)$")
      if dx and view then
        local f = view:frame()
        if f then view:frame({ x = f.x + tonumber(dx), y = f.y + tonumber(dy),
                               w = f.w, h = f.h }) end
      end
    elseif cmd == "save" and data then
      local ok, incoming = pcall(hs.json.decode, data)
      if not ok or type(incoming) ~= "table" then
        hs.notify.new({ title = "GhostType",
          informativeText = "Settings not saved (invalid data)" }):send()
        return -- window stays open
      end
      local _, warnings = M.applySettings(config, incoming)
      if callbacks and callbacks.onSaved then callbacks.onSaved(warnings) end
      if view then view:delete(); view = nil end
    end
  end)

  local sw = hs.screen.mainScreen():frame()
  local w, h = 520, 640
  view = hs.webview.new(
    { x = sw.x + (sw.w - w) / 2, y = sw.y + (sw.h - h) / 2,
      w = w, h = h },
    { developerExtrasEnabled = false }, uc)
  view:windowStyle({ "borderless", "resizable" })
  view:allowTextEntry(true)
  view:level(hs.drawing.windowLevels.floating)
  view:html(M.build(config))
  view:windowCallback(function(action) if action == "closing" then view = nil end end)
  view:show()
  M._view = view -- debug/diagnostic handle (evaluateJavaScript-driven tests)
  local hw = view:hswindow(); if hw then hw:focus() end
end

return M
