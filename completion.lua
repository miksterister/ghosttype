-- GhostType · completion.lua
-- Talks to the local GhostType FIM server: POST /complete with {prefix, suffix}
-- returns {text}; readiness via GET /ready. Same hs.task + curl + tmpfile pattern
-- as textlens/ollama.lua, but non-streaming: ghost-text completions are short
-- (a handful of tokens) so a single blocking round-trip is simple and fast.

local M = {}

local function writeBody(path, s)
  local f = io.open(path, "w")
  if f then f:write(s); f:close() end
end

-- Requests a completion for `prompt`. Returns the hs.task so the caller can
-- :terminate() it if a newer keystroke makes this request stale.
-- onDone(text) is called with the raw suggestion text (may be "").
-- onError(msg) is called on any failure; callers should treat this as
-- "no suggestion this time" rather than surfacing it to the user.
function M.request(cfg, prefix, suffix, onDone, onError)
  local url      = cfg.serverUrl .. "/complete"
  local body     = hs.json.encode({
    prefix     = prefix,
    suffix     = suffix or "",
    max_tokens = cfg.maxTokens or 8,
    -- Without max_words the token budget is the only stop, so suggestions ran
    -- to 8 words and ended mid-phrase. The Obsidian plugin always sent this.
    max_words  = cfg.maxWords or 4,
  })
  local bodyFile = os.tmpname()
  writeBody(bodyFile, body)

  local task = hs.task.new("/usr/bin/curl", function(code, out, err)
    os.remove(bodyFile)
    if code ~= 0 then
      onError("curl exit " .. code .. (err and err ~= "" and (": " .. err) or ""))
      return
    end
    local ok, data = pcall(hs.json.decode, out)
    if not ok or not data then
      onError("bad response from ghosttype server")
      return
    end
    if data.error then
      onError(tostring(data.error.message or data.error))
      return
    end
    onDone(data.text or "")
  end, {
    "-s", "-X", "POST", "-H", "Content-Type: application/json",
    "--connect-timeout", "1",
    "--max-time", tostring(cfg.requestTimeoutSec or 2),
    "--data-binary", "@" .. bodyFile, url,
  })

  task:start()
  return task
end

-- Hits /ready to confirm the server is up before the first suggestion attempt.
-- callback(up, errMsg). NOTE: checks curl's exit code, not the HTTP status, so a
-- 503 (model still loading) would read as "up" — fine ONLY because the server
-- eager-loads inside uvicorn's lifespan startup, before the socket accepts
-- connections (mid-load → connection refused → down; once accepting → already
-- 200). If model load ever moves off the startup path, add `-f` to this curl.
function M.checkServer(cfg, callback)
  hs.task.new("/usr/bin/curl", function(code, _out, _err)
    if code == 0 then
      callback(true, nil)
    else
      callback(false, "Cannot reach GhostType server at " .. cfg.serverUrl
        .. "\nRun: server/start_server.sh")
    end
  end, { "-s", "-o", "/dev/null", "--connect-timeout", "1", cfg.serverUrl .. "/ready" }):start()
end

return M
