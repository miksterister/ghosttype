package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local settings = require("settings")

local function baseConfig()
  return {
    enabled = true,
    toggleHotkey = { mods = { "cmd", "alt" }, key = "g" },
    serverUrl = "http://127.0.0.1:8790",
    model = "decorative-model-key",
    idleMs = 220, maxTokens = 8, fontSize = 14, fontName = ".AppleSystemUIFont",
    minPrefixChars = 12, maxPrefixChars = 800, maxSuffixChars = 200,
    requestTimeoutSec = 2,
    ghostColor = { red = 0.55, green = 0.55, blue = 0.58, alpha = 0.85 },
    fallbackCharWidth = 8, fallbackLineHeight = 20, fallbackLeftPad = 4,
    apps = {
      ["Notes"] = { enabled = true, tier = 1 },
      ["Arc"]   = { enabled = true, tier = 2,
                    titlePatterns = { "Claude" }, sitePatterns = { "claude.ai" } },
    },
  }
end

-- known keys merge; unknown/injected top-level keys ignored
local cfg = baseConfig()
local _, w = settings.applySettings(cfg, { idleMs = 300, evil = "x" })
T.eq(cfg.idleMs, 300, "idleMs merged")
T.eq(cfg.evil, nil, "unknown key ignored")
T.eq(#w, 0, "clean save has no warnings")

-- UI-absent keys preserved (model survives a save)
cfg = baseConfig()
settings.applySettings(cfg, { idleMs = 250 })
T.eq(cfg.model, "decorative-model-key", "model preserved")

-- clamping
cfg = baseConfig()
settings.applySettings(cfg, { idleMs = 50, maxTokens = 99, fontSize = 100 })
T.eq(cfg.idleMs, 100, "idleMs clamped low")
T.eq(cfg.maxTokens, 20, "maxTokens clamped high")
T.eq(cfg.fontSize, 36, "fontSize clamped high")

-- non-numeric keeps old
cfg = baseConfig()
settings.applySettings(cfg, { idleMs = "banana" })
T.eq(cfg.idleMs, 220, "non-numeric keeps old")

-- min/max prefix pair invariant
cfg = baseConfig()
local _, w2 = settings.applySettings(cfg, { minPrefixChars = 900, maxPrefixChars = 800 })
T.eq(cfg.minPrefixChars, 12, "min>max keeps old min")
T.eq(cfg.maxPrefixChars, 800, "min>max keeps old max")
T.eq(#w2 > 0, true, "min>max warns")
cfg = baseConfig()
settings.applySettings(cfg, { minPrefixChars = 20, maxPrefixChars = 1000 })
T.eq(cfg.minPrefixChars, 20, "valid pair min applied")
T.eq(cfg.maxPrefixChars, 1000, "valid pair max applied")

-- apps contract
cfg = baseConfig()
settings.applySettings(cfg, { apps = {
  ["Arc"]     = { enabled = false, tier = 99, sitePatterns = { "chatgpt.com" } },
  ["Notes"]   = { enabled = false, sitePatterns = { "evil.com" } },
  ["Phantom"] = { enabled = true },
} })
T.eq(cfg.apps["Arc"].enabled, false, "app enabled updated")
T.eq(cfg.apps["Arc"].tier, 2, "tier injection ignored")
T.eq(cfg.apps["Arc"].sitePatterns[1], "chatgpt.com", "browser patterns updated")
T.eq(cfg.apps["Notes"].sitePatterns, nil, "patterns rejected for non-browser")
T.eq(cfg.apps["Notes"].enabled, false, "non-browser enabled still updates")
T.eq(cfg.apps["Phantom"], nil, "unknown app ignored")

-- bad pattern list keeps old
cfg = baseConfig()
settings.applySettings(cfg, { apps = { ["Arc"] = { sitePatterns = { 1, 2 } } } })
T.eq(cfg.apps["Arc"].sitePatterns[1], "claude.ai", "bad pattern list keeps old")

-- hotkey validation
T.eq(settings.validateHotkey({ mods = { "cmd", "bogus" }, key = "G" }).key, "g", "key lowercased")
T.eq(#settings.validateHotkey({ mods = { "cmd", "bogus" }, key = "G" }).mods, 1, "unknown mod dropped")
T.eq(settings.validateHotkey({ mods = {}, key = "g" }), nil, "modifier-less rejected")
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = "ArrowRight" }), nil, "arrow rejected")
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = "" }), nil, "empty key rejected")
cfg = baseConfig()
local _, w3 = settings.applySettings(cfg, { toggleHotkey = { mods = {}, key = "g" }, idleMs = 260 })
T.eq(cfg.toggleHotkey.key, "g", "invalid hotkey keeps old")
T.eq(cfg.toggleHotkey.mods[1], "cmd", "invalid hotkey keeps old mods")
T.eq(cfg.idleMs, 260, "rest of save still applies")
T.eq(#w3 > 0, true, "invalid hotkey warns")

-- ghostColor
local c = settings.parseColor("#ff0080", 0.5)
T.eq(c.red, 1, "hex red")
T.eq(c.green, 0, "hex green")
T.eq(c.alpha, 0.5, "alpha kept")
T.eq(settings.parseColor("#ff0080", 2).alpha, 1, "alpha clamped")
T.eq(settings.parseColor("red", 0.5), nil, "bad hex nil")
cfg = baseConfig()
settings.applySettings(cfg, { ghostHex = "nope", ghostAlpha = 0.5 })
T.eq(cfg.ghostColor.red, 0.55, "malformed color preserves whole old color")

-- enabled / booleans coerced strictly
cfg = baseConfig()
settings.applySettings(cfg, { enabled = "truthy string" })
T.eq(cfg.enabled, false, "non-true coerces to false")

-- serverUrl must look like a URL
cfg = baseConfig()
settings.applySettings(cfg, { serverUrl = "not a url" })
T.eq(cfg.serverUrl, "http://127.0.0.1:8790", "bad serverUrl keeps old")

-- e.key dialect normalization / allowlist
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = "Enter" }).key, "return", "enter normalized to return")
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = " " }).key, "space", "space normalized")
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = "Backspace" }).key, "delete", "backspace normalized")
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = "F5" }).key, "f5", "function keys allowed")
T.eq(settings.validateHotkey({ mods = { "cmd" }, key = "MediaPlay" }), nil, "unknown multi-char name rejected")

-- maxTokens below 2×maxWords: the budget pre-empts the word cap and suggestions
-- end mid-word. The UI can produce this (maxTokens is draggable, maxWords is
-- not), so it warns rather than failing silently.
local cfgW = { enabled = true, maxWords = 4, maxTokens = 10, apps = {} }
local _, wOk = settings.applySettings(cfgW, { maxTokens = 10 })
T.eq(#wOk, 0, "10 tokens for 4 words is fine")

local cfgB = { enabled = true, maxWords = 4, maxTokens = 10, apps = {} }
local _, wBad = settings.applySettings(cfgB, { maxTokens = 5 })
T.eq(#wBad, 1, "5 tokens for 4 words warns")
T.ok(wBad[1]:find("mid-word", 1, true), "warning explains the symptom")
T.ok(wBad[1]:find("8+", 1, true), "warning names the minimum that works")

-- The default pairing must not warn, or every save nags.
local cfgD = { enabled = true, maxWords = 4, maxTokens = 8, apps = {} }
local _, wDef = settings.applySettings(cfgD, {})
T.eq(#wDef, 0, "the 2x boundary itself is acceptable")

T.finish("settings")