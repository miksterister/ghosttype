-- GhostType · log.lua
-- Append-only prediction/suppression log for observability during live use.
-- Pure formatting (tail/format) is host-free and unit-tested; the writer does
-- file I/O and prepends the timestamp. Truncated once per launch (reset) so it
-- stays readable across sessions.

local M = {}

M.LOG_PATH = os.getenv("HOME") .. "/Library/Logs/ghosttype/predictions.log"

-- Last `n` characters of the context, newline-flattened, ellipsis-prefixed when
-- truncated. A byte slice is fine: this string is for human eyes in a log, not
-- model input, so grapheme-exactness does not matter here.
function M.tail(ctx, n)
  ctx = ctx or ""
  n = n or 40
  ctx = ctx:gsub("\n", " ")
  if #ctx <= n then return ctx end
  return "…" .. ctx:sub(#ctx - n + 1)
end

-- Formats one prediction line WITHOUT a timestamp (kept deterministic for
-- tests; the writer prepends the timestamp).
function M.format(entry)
  local app = entry.app or "?"
  local ctx = M.tail(entry.ctx, entry.ctxChars or 40)
  if entry.outcome == "shown" then
    return string.format('PREDICT app=%q ctx=%q → SHOWN %q', app, ctx, entry.text or "")
  end
  if entry.outcome == "reused" then
    return string.format('PREDICT app=%q ctx=%q → REUSED %q', app, ctx, entry.text or "")
  end
  if entry.outcome == "accepted" then
    return string.format('PREDICT app=%q ctx=%q → ACCEPTED %q', app, ctx, entry.text or "")
  end
  if entry.outcome == "spell-accept" or entry.outcome == "spell-skip" then
    return string.format('SPELL app=%q %s %q → %q', app,
      entry.outcome == "spell-accept" and "ACCEPT" or "SKIP",
      entry.original or "", entry.suggestion or "")
  end
  if entry.outcome == "check" then
    -- spellcheck run: what was read from the field and what the server said
    local head = string.format('CHECK app=%q role=%q chars=%d ctx=%q', app,
      entry.role or "?", entry.chars or 0, ctx)
    if entry.status then return head .. " → FAILED status=" .. tostring(entry.status) end
    return string.format("%s → %d issues, %d skipped", head, entry.issues or 0, entry.skipped or 0)
  end
  return string.format('PREDICT app=%q ctx=%q → SUPPRESS(%s)', app, ctx, entry.reason or "?")
end

local function ensureDir(path)
  local dir = path:match("(.+)/[^/]+$")
  if dir then os.execute('mkdir -p "' .. dir .. '"') end
end

-- Rotate-per-launch, not truncate. The accept rate is the only number that says
-- whether a model or prompt change helped, and it lives ONLY here — truncating
-- on every hs.reload() destroyed the baseline exactly when you reloaded to test
-- the change you wanted to measure. One generation back is enough to compare a
-- session against the one before it.
M.PREV_SUFFIX = ".prev"

function M.reset(path)
  path = path or M.LOG_PATH
  ensureDir(path)
  os.remove(path .. M.PREV_SUFFIX)
  os.rename(path, path .. M.PREV_SUFFIX) -- no-op when there is nothing to rotate
  local f = io.open(path, "w")
  if f then f:close() end
end

-- Append one timestamped prediction line.
function M.write(entry, path)
  path = path or M.LOG_PATH
  ensureDir(path)
  local line = os.date("%Y-%m-%d %H:%M:%S ") .. M.format(entry)
  local f = io.open(path, "a")
  if f then f:write(line, "\n"); f:close() end
end

return M
