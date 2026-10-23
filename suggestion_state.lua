-- GhostType · suggestion_state.lua
-- Pure suggestion cleanup/reuse helpers plus prompt framing. Kept host-free so
-- the fragile typing state machine can be unit-tested outside Hammerspoon.

local M = {}

-- ── Prompt framing (ported from the Obsidian plugin) ─────────────────────────
-- The plugin prefixes the FIM window with "# <note basename>" plus the headings
-- enclosing the caret, so the model knows what the document is about. Only the
-- title half ports: Hammerspoon has no metadataCache, just a window title, and
-- reconstructing markdown structure would serve exactly one app (Typora).
--
-- The gate matters more than the framing. A window title is often NOT a
-- document name — Claude desktop titles its window "Claude" — and a base model
-- parrots whatever you prepend, which is the same failure that made
-- personalization index completed sentences rather than accepted fragments.
-- Better no frame than a meaningless one. Returns a clean title, or nil.
local CHROME_SEPARATORS = { " — ", " – ", " - ", " | " }

function M.documentTitle(appName, windowTitle)
  if type(windowTitle) ~= "string" then return nil end
  local t = windowTitle

  t = t:gsub("^%(%d+%)%s*", "")           -- unread badge: "(1) Foo" (Arc, Mail)

  -- Trailing app-name chrome ("Q3 Report — Microsoft Word"). Plain suffix
  -- comparison, not a pattern: an em dash is multi-byte UTF-8 and app names
  -- contain pattern magic (the "-" in "Adobe Photoshop 2023 - x").
  if type(appName) == "string" and appName ~= "" then
    for _, sep in ipairs(CHROME_SEPARATORS) do
      local suffix = sep .. appName
      if #t > #suffix and t:sub(-#suffix) == suffix then
        t = t:sub(1, #t - #suffix)
        break
      end
    end
  end

  t = t:gsub("%.%a%a?%a?%a?$", "")        -- file extension: .md, .docx, .txt
  t = t:gsub("^%s+", ""):gsub("%s+$", "")

  if t == "" then return nil end
  if type(appName) == "string" and t:lower() == appName:lower() then return nil end
  if t:lower():match("^untitled") then return nil end
  if (utf8.len(t) or #t) < 3 then return nil end
  return t
end

-- The framing string to prepend to the prompt, or "" when the title is not
-- worth framing with. Mirrors the plugin's markdown so the FIM prompt stays one
-- coherent document. Prepend to the PROMPT only, never to the prefix the
-- staleness and reuse checks compare against.
function M.titleFrame(appName, windowTitle)
  local t = M.documentTitle(appName, windowTitle)
  if not t then return "" end
  return "# " .. t .. "\n\n"
end

-- Keeps only the first line and trims trailing whitespace. Ghost text is a
-- short inline continuation, not a multi-paragraph completion.
function M.cleanSuggestion(text)
  if not text then return "" end
  text = text:gsub("\r", "")
  local nl = text:find("\n")
  if nl then text = text:sub(1, nl - 1) end
  text = text:gsub("%s+$", "")
  return text
end

-- Caret-boundary sanitization. Base models continue a clean word boundary far
-- better than a dangling trailing space, which tokenizes oddly and derails the
-- completion into garbage ("The quick brown fox " → "10000000" vs "The quick
-- brown fox" → "jumps over the lazy dog"). Strip trailing whitespace from the
-- prompt before sending. Returns trimmedPrompt, didTrim.
function M.trimPromptEnd(prefix)
  if type(prefix) ~= "string" then return prefix, false end
  local trimmed = (prefix:gsub("%s+$", ""))
  return trimmed, trimmed ~= prefix
end

-- Reconcile the candidate side of that trim: when we stripped a trailing space
-- from the prompt, the user has already typed that separator, so drop any
-- leading whitespace the model reintroduces to avoid a double space on insert.
-- When we did not trim (caret sits on a non-space), keep the model's leading
-- space — it is the separator before a genuinely new word.
function M.reconcileLeadingSpace(text, didTrim)
  if not didTrim or type(text) ~= "string" then return text end
  return (text:gsub("^%s+", ""))
end

-- Trim-and-reuse: if the user typed the leading characters of the last shown
-- suggestion, return the remaining ghost text instead of requiring a model
-- round-trip.
--
-- Returns:
--   handled:boolean  true when the caller should not fetch a new suggestion
--   remaining:string|nil  text to show; nil means the suggestion was fully typed
--
-- Both prefixes are trailing *windows* (maxPrefixChars), not true prefixes:
-- past the cap the newer window starts later, so a startswith test reported
-- "diverged" on every keystroke and long documents refetched per character.
-- Anchor on the shared tail instead — both windows end at the caret.
function M.reuseSuggestion(lastSuggestion, freshPrefix)
  if not lastSuggestion then return false, nil end
  local base = lastSuggestion.prefix or ""
  local text = lastSuggestion.text or ""
  freshPrefix = freshPrefix or ""
  if base == "" then return false, nil end

  -- k = leading suggestion chars already typed; a few words, so scanning is cheap.
  for k = 0, #text do
    local cand = base .. text:sub(1, k)
    local n = math.min(#cand, #freshPrefix)
    if n > 0 and cand:sub(-n) == freshPrefix:sub(-n) then
      local remaining = text:sub(k + 1)
      if remaining == "" then return true, nil end -- fully typed
      return true, remaining
    end
  end
  return false, nil -- diverged, or typed off-script
end

-- Has the AX value caught up with the last keystroke? Chromium (Claude) updates
-- AXValue asynchronously, so a read right after typing "e" can still end in
-- "y" — and reuseSuggestion then happily re-shows the untrimmed ghost after
-- the new char ("ye" + "eet."). nil tail = nothing to check (delete, return).
function M.caughtUp(prefix, typedTail)
  if not typedTail or typedTail == "" then return true end
  return type(prefix) == "string" and prefix:sub(-#typedTail) == typedTail
end

-- The next word of a suggestion (with its leading whitespace), for word-by-word
-- acceptance (§). Returns chunk, rest — or nil when there is no word to take.
-- Mirrors nextChunk in the Obsidian plugin.
function M.nextChunk(text)
  local chunk = type(text) == "string" and text:match("^%s*%S+")
  if not chunk then return nil end
  return chunk, text:sub(#chunk + 1)
end


return M
