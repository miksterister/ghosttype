-- GhostType · config.lua
-- Config I/O and defaults. Mirrors textlens/config.lua conventions.

local M = {}

M.CONFIG_PATH = os.getenv("HOME") .. "/.config/ghosttype/config.json"

local function mkdirp(dir)
  if not dir or dir == "" or dir == "/" then return end
  if hs.fs.attributes(dir) then return end
  local parent = dir:match("^(.+)/[^/]+$")
  mkdirp(parent)
  hs.fs.mkdir(dir)
end

-- Tiers (informational, used for status/logging only):
--   1 = native Cocoa text views (Notes, Mail) — full AX support, most reliable
--   2 = Chromium/Electron web content (Claude desktop, browsers) — usually
--       works but the accessibility tree can take a beat to warm up after
--       switching tabs/windows
--   3 = experimental — apps assumed to expose little or no live
--       AXValue/AXSelectedTextRange. NOTE (2026-09-18): the ⌘⌥P probe
--       measured this tier and it did not survive contact. Word, PowerPoint
--       (inside a text box) and Outlook all report `full` — exact AXValue,
--       caret offset and caret bounds — so they are tier 1 here. Nothing is
--       tier 3 any more; the label is kept only so an app can be parked here
--       after a probe actually says no-go. Measure before you assume:
--       ⌘⌥P, then read ~/Library/Logs/ghosttype/probe.log.
M.DEFAULT = {
  enabled      = true,
  toggleHotkey = { mods = { "cmd", "alt" }, key = "g" },

  -- Spellcheck is a separate, on-demand surface: it checks the paragraph around
  -- the caret and offers suggestions you accept by number. It never edits on its
  -- own, and it shares `enabled` with completion (one master switch).
  checkHotkey     = { mods = { "cmd", "alt" }, key = "s" },
  -- Second opinion: same check through a bigger model. Slow (~2.5 s/sentence)
  -- but catches real-word errors the fast pass misses. Also [b] in the panel.
  checkDeepHotkey = { mods = { "cmd", "alt", "shift" }, key = "s" },
  spellDeepModel  = "gemma4:31b",

  -- Probe (⌘⌥P): reports what the focused field's AX interface actually exposes
  -- and whether GhostType could work there. A hotkey rather than a menubar item
  -- because the probe must read the element while the caret is still IN it —
  -- clicking away to a menu is exactly what we cannot do. Diagnostic only: it
  -- ignores `apps`, so unlisted apps can be measured before being enabled.
  probeHotkey     = { mods = { "cmd", "alt" }, key = "p" },
  spellServerUrl  = "http://127.0.0.1:8791",
  spellMaxChars   = 4000,

  serverUrl          = "http://127.0.0.1:8790",
  -- DECORATIVE: the client never sends this — the server picks its model from
  -- MODEL in server/ghosttype_server.py (GHOSTTYPE_MODEL env overrides). Kept for
  -- backward compat with existing config files; shown read-only in Settings.
  -- NOTE: quality depends heavily on sending a clean word boundary — see
  -- suggestion_state.trimPromptEnd; a dangling trailing space derails the
  -- model badly.
  model              = "mlx-community/Qwen2.5-Coder-1.5B-4bit",

  idleMs             = 220,   -- debounce after last keystroke before requesting a suggestion
  -- maxWords is the clean-boundary stop; maxTokens is only a budget ceiling.
  -- Keep maxTokens ≳ 2×maxWords or the budget fires first and the word cap
  -- never binds, ending the suggestion mid-word. 10/4 matches the Obsidian
  -- plugin (MAX_TOKENS/MAX_WORDS in obsidian-plugin/main.js) so both clients
  -- produce the same shape of ghost text. maxWords was previously absent from
  -- these defaults, reachable only as completion.lua's hardcoded fallback.
  maxTokens          = 10,    -- budget ceiling; raise with maxWords, not alone
  maxWords           = 4,     -- ghost text is a nudge, not a paragraph
  minPrefixChars     = 12,    -- below this the model has no context and free-associates junk (seen live in Claude's empty chat box)
  -- How much preceding text to send. The Obsidian plugin sends 2000 and is the
  -- client with the better accept rate; 1200 is the measured middle — 2000 cost
  -- +66 ms median (173 → 239 ms) against 800 on granite-1b, 2026-09-18.
  maxPrefixChars     = 1200,  -- how much preceding text to send as context
  -- Frame the prompt with "# <document title>", ported from the Obsidian
  -- plugin. Off = send the raw window only. Kept as a switch so the effect on
  -- the accept rate can be measured against predictions.log.prev rather than
  -- assumed — the geometry fix is moving that number at the same time.
  contextTitle       = true,
  maxSuffixChars     = 200,   -- how much after-caret text to send as the FIM suffix
  requestTimeoutSec  = 2,

  ghostColor = { red = 0.55, green = 0.55, blue = 0.58, alpha = 0.85 },
  fontName   = ".AppleSystemUIFont",
  fontSize   = 14,

  -- Fallback caret-geometry metrics, used only when an app (e.g. Obsidian/
  -- CodeMirror) returns a degenerate AXBoundsForRange (w=h=0). Tunable because
  -- the editor's true font metrics are unknown to us — calibrate live.
  fallbackCharWidth  = 8,   -- estimated px per character on the current line
  fallbackLineHeight = 20,  -- estimated line height in px
  fallbackLeftPad    = 4,   -- px from the text element's left edge to the first glyph

  apps = {
    ["Notes"]                 = { enabled = true,  tier = 1 },
    ["Mail"]                  = { enabled = true,  tier = 1 },
    ["Claude"]                = { enabled = true,  tier = 2 },
    ["Arc"]                   = { enabled = true,  tier = 2, titlePatterns = { "Claude", "ChatGPT", "Gemini" }, sitePatterns = { "claude.ai", "chatgpt.com", "gemini.google.com" } },
    ["Google Chrome"]         = { enabled = true,  tier = 2, titlePatterns = { "Claude", "ChatGPT", "Gemini" }, sitePatterns = { "claude.ai", "chatgpt.com", "gemini.google.com" } },
    ["Vivaldi"]                = { enabled = true,  tier = 2, titlePatterns = { "Claude", "ChatGPT", "Gemini" }, sitePatterns = { "claude.ai", "chatgpt.com", "gemini.google.com" } },
    ["Safari"]                 = { enabled = true,  tier = 2, titlePatterns = { "Claude", "ChatGPT", "Gemini" }, sitePatterns = { "claude.ai", "chatgpt.com", "gemini.google.com" } },
    -- Probed full on 2026-09-18 (real AXValue + caret offset + caret bounds),
    -- which is why these are tier 1 and on by default despite the old README
    -- claiming Word "would mostly do nothing". PowerPoint only answers inside a
    -- text box in edit mode; its slide canvas is an AXScrollArea and no-gos
    -- cleanly, so enabling it costs nothing on the slide itself.
    ["Microsoft Word"]         = { enabled = true,  tier = 1 },
    ["Microsoft PowerPoint"]   = { enabled = true,  tier = 1 },
    ["Microsoft Outlook"]      = { enabled = true,  tier = 1 },
    ["Typora"]                 = { enabled = true,  tier = 1 },
    -- Obsidian stays OFF: the CM6 plugin owns that editor and renders ghost
    -- text pixel-true. Two engines both bind Tab/§ and the system-level
    -- eventtap wins, so you accept a suggestion you were not looking at.
    ["Obsidian"]                = { enabled = false, tier = 3 },
  },
}

local function copyMissing(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then
      if type(v) == "table" then
        dst[k] = hs.json.decode(hs.json.encode(v))
      else
        dst[k] = v
      end
    elseif k == "apps" and type(dst[k]) == "table" and type(v) == "table" then
      -- Preserve per-app user overrides, but add newly-supported default apps on
      -- upgrade so old configs do not silently miss new compatibility profiles.
      for appName, appDefault in pairs(v) do
        if dst[k][appName] == nil then
          dst[k][appName] = hs.json.decode(hs.json.encode(appDefault))
        elseif type(dst[k][appName]) == "table" and type(appDefault) == "table" then
          copyMissing(dst[k][appName], appDefault)
        end
      end
    elseif type(dst[k]) == "table" and type(v) == "table" then
      -- Array-valued keys (pattern lists, hotkey mods) are atomic user values:
      -- back-filling "missing" integer slots from the defaults would resurrect
      -- deleted entries / regrow shortened lists on every load.
      if dst[k][1] == nil and v[1] == nil then copyMissing(dst[k], v) end
    end
  end
  return dst
end

function M.readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

function M.writeFile(path, s)
  mkdirp(path:match("(.+)/[^/]+$"))
  local f = io.open(path, "w")
  if f then f:write(s); f:close() end
end

function M.load()
  local raw = M.readFile(M.CONFIG_PATH)
  if raw then
    local ok, cfg = pcall(hs.json.decode, raw)
    if ok and cfg then return copyMissing(cfg, M.DEFAULT) end
    hs.timer.doAfter(0.5, function()
      hs.notify.new({ title = "GhostType",
        informativeText = "Config was corrupted and has been reset to defaults" }):send()
    end)
  end
  return hs.json.decode(hs.json.encode(M.DEFAULT))
end

function M.save(cfg)
  M.writeFile(M.CONFIG_PATH, hs.json.encode(cfg))
end

return M
