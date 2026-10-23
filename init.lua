-- ┌─────────────────────────────────────────────────────────────┐
-- │  GhostType for Hammerspoon                                   │
-- │  Cotypist-lite: inline ghost-text completion, local model,   │
-- │  scoped to a small set of apps you actually type long text   │
-- │  into (Notes, Mail, Claude, browsers; Word/PowerPoint/       │
-- │  Obsidian available as experimental opt-ins).                │
-- └─────────────────────────────────────────────────────────────┘

local M = {}

local cfg_mod   = require("ghosttype.config")
local caret     = require("ghosttype.caret")
local overlay   = require("ghosttype.overlay")
local completion = require("ghosttype.completion")
local suggestion = require("ghosttype.suggestion_state")
local profiles  = require("ghosttype.app_profiles")
local logmod    = require("ghosttype.log")
local menubar   = require("ghosttype.menubar")
local settings  = require("ghosttype.settings")
local spellcheck  = require("ghosttype.spellcheck")
local probe     = require("ghosttype.probe")

-- ── State ─────────────────────────────────────────────────────────────────────
local config          = cfg_mod.load()
local currentSuggestion = nil
local lastSuggestion    = nil  -- {text, prefix}: kept after the overlay hides so
                               -- the next debounce can trim-and-reuse it (see
                               -- reuseSuggestion) instead of always refetching.
local debounceTimer   = nil
local activeReqTask    = nil
local activeReqId      = 0
local tap              = nil
local appWatcher        = nil
local toggleHotkeyBind  = nil
local checkHotkeyBind   = nil
local checkDeepHotkeyBind = nil
local probeHotkeyBind   = nil

-- Server reachability tracking. `serverUp` flips to false the first time a
-- request fails to connect; a poller then rechecks until it recovers, so a
-- server that was down at login (or died mid-session) reconnects on its own
-- instead of silently no-opping forever.
local serverUp        = true
local recheckTimer    = nil

-- Word-accept (Tab) / accept bookkeeping: while suppressUntil is in the future, keyDown
-- events are the replayed synthetic keystrokes of an accepted chunk and must
-- not hide the ghost or schedule a refetch. reshowTimer re-anchors the
-- remainder at the fresh caret once the insertion has landed.
local suppressUntil   = 0

-- The character the last scheduling keystroke typed (nil for delete/return).
-- requestSuggestion waits for the AX prefix to end with it — see caughtUp.
local typedTail       = nil
local reshowTimer     = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- Soft hide: removes the visible overlay but keeps `lastSuggestion` so a
-- follow-on keystroke can trim-and-reuse it. Used on the typing path.
local function clearSuggestion()
  if currentSuggestion then
    currentSuggestion = nil
    overlay.hide()
  end
end

-- Hard forget: hide *and* drop the remembered suggestion. Used whenever the
-- context has genuinely changed (accept, dismiss, click, scroll, app switch),
-- so a stale suggestion can never be revived over unrelated text.
local function forgetSuggestion()
  clearSuggestion()
  lastSuggestion = nil
end

local function cancelPending()
  if debounceTimer then debounceTimer:stop(); debounceTimer = nil end
  activeReqId = activeReqId + 1
  if activeReqTask then pcall(function() activeReqTask:terminate() end); activeReqTask = nil end
end

-- ── Server reachability ─────────────────────────────────────────────────────
local markServerDown  -- forward decl (referenced by the recheck poller)

local function stopRecheck()
  if recheckTimer then recheckTimer:stop(); recheckTimer = nil end
end

-- Polls the server while it's down; on recovery, stops itself and notifies once.
local function startRecheck()
  if recheckTimer then return end
  recheckTimer = hs.timer.doEvery(5, function()
    completion.checkServer(config, function(up)
      if up then
        stopRecheck()
        if not serverUp then
          serverUp = true
          menubar.setServerUp(true)
          hs.notify.new({ title = "GhostType",
            informativeText = "Completion server reconnected — suggestions back on" }):send()
        end
      end
    end)
  end)
end

-- Called on a connection failure. Notifies once on the up→down edge and starts
-- the recovery poller. Repeated failures while already down are quiet.
markServerDown = function()
  if serverUp then
    serverUp = false
    menubar.setServerUp(false)
    hs.notify.new({ title = "GhostType",
      informativeText = "Completion server unreachable — retrying, suggestions paused" }):send()
  end
  startRecheck()
end

-- Keeps only the first line and trims trailing whitespace. Ghost text is a
-- short inline continuation, not a multi-paragraph completion.
local function cleanSuggestion(text)
  return suggestion.cleanSuggestion(text)
end

-- Records one prediction outcome to the log and bumps the menubar tally.
-- outcome is "shown" (detail = suggestion text) or "suppress" (detail = reason).
local function logPredict(appName, prefix, outcome, detail)
  local entry = { app = appName, ctx = prefix, outcome = outcome }
  if outcome == "shown" or outcome == "reused" or outcome == "accepted" then
    entry.text = detail
  else
    entry.reason = detail
  end
  logmod.write(entry)
  if outcome ~= "accepted" then menubar.tally(outcome) end  -- menubar.tally branches on shown/reused/else
end

local function showSuggestion(rect, text, prefix)
  currentSuggestion = text
  lastSuggestion    = { text = text, prefix = prefix }
  overlay.show(rect, text, config)
end

-- Tab word-accept: insert one word, keep the rest as the active ghost. The
-- synthetic keystrokes from insertText are swallowed by the suppression window
-- instead of replaying through the debounce, and the remainder re-anchors at
-- the fresh caret shortly after — so a Tab-chain never has its text regenerate
-- out from under it; only real typing triggers a new fetch.
local function acceptWord(chunk, rest, app)
  if rest == "" then rest = nil end
  overlay.hide()
  currentSuggestion = rest
  lastSuggestion = nil -- prefix is stale until re-anchored below
  if reshowTimer then reshowTimer:stop(); reshowTimer = nil end
  cancelPending()
  suppressUntil = hs.timer.secondsSinceEpoch() + 0.5
  logPredict(app and app:name() or "?", "", "accepted", chunk)
  caret.insertText(chunk)
  if not rest then return end
  reshowTimer = hs.timer.doAfter(0.25, function()
    reshowTimer = nil
    if currentSuggestion ~= rest then return end -- dismissed or chained past meanwhile
    local fb = { charWidth = config.fallbackCharWidth, lineHeight = config.fallbackLineHeight, leftPad = config.fallbackLeftPad }
    local fresh = caret.getFocusedContext(app, config.maxPrefixChars, config.maxSuffixChars, fb)
    if fresh then
      showSuggestion(fresh.rect, rest, fresh.prefix)
      logPredict(app:name(), fresh.prefix, "reused", rest)
    end
  end)
end

-- Trim-and-reuse: if the just-typed characters are the leading characters of
-- the suggestion we last showed, we already know the answer — shorten the ghost
-- text locally instead of asking the model again. Returns true if it handled
-- the update (either by reshowing a trimmed suggestion or confirming there's
-- nothing left to show). This is what makes typing *into* a suggestion feel
-- instant rather than incurring a round-trip per character.
-- byte-prefix match; correct for the ASCII/Latin common case, and a miss just
-- falls through to a normal fetch, so no need for grapheme-awareness.
local function reuseSuggestion(fresh, appName)
  local handled, remaining = suggestion.reuseSuggestion(lastSuggestion, fresh.prefix)
  if not handled then return false end
  if not remaining then
    clearSuggestion(); lastSuggestion = nil
    return true
  end
  showSuggestion(fresh.rect, remaining, fresh.prefix)
  logPredict(appName, fresh.prefix, "reused", remaining)
  return true
end

-- The tab URL is the primary site-filter signal: named AI-chat conversations
-- title the tab with just the conversation name, so window titles only
-- identify new-tab pages. AppleScript is the one uniform way to read the
-- active tab's URL across these browsers (AX has no stable path for it).
-- Requires the one-time Automation permission (Hammerspoon → each browser);
-- until granted, the call fails quietly and the title fallback still applies.
local AS_URL = {
  ["Safari"]        = 'tell application "Safari" to return URL of current tab of front window',
  ["Arc"]           = 'tell application "Arc" to return URL of active tab of front window',
  ["Google Chrome"] = 'tell application "Google Chrome" to return URL of active tab of front window',
  ["Vivaldi"]       = 'tell application "Vivaldi" to return URL of active tab of front window',
}

local function frontTabUrl(appName)
  local script = AS_URL[appName]
  if not script then return nil end
  local okCall, ok, result = pcall(hs.osascript.applescript, script)
  if okCall and ok and type(result) == "string" then return result end
  return nil
end

local function requestSuggestion(app, attempt)
  if not app then return end
  if not profiles.isEnabledFor(config, app:name()) then return end

  -- Site filter (DEC-005): browsers only fire on AI-chat pages — URL primary,
  -- title fallback. Runs after the debounce so the AX/AppleScript calls are
  -- per-request, not per-keystroke. Hard-forget: a tab switch must never let
  -- lastSuggestion revive a ghost from an allowed tab on a blocked page.
  local appName = app:name()
  local win = app:focusedWindow()
  local title = win and win:title() or nil
  local url = frontTabUrl(appName)
  if not profiles.siteAllowed(config, appName, title, url) then
    forgetSuggestion()
    logPredict(appName, "", "suppress", ("site-filter t=%s u=%s")
      :format(tostring(title):sub(1, 40), tostring(url):sub(1, 60)))
    return
  end

  local fb = { charWidth = config.fallbackCharWidth, lineHeight = config.fallbackLineHeight, leftPad = config.fallbackLeftPad }
  local ctx = caret.getFocusedContext(app, config.maxPrefixChars, config.maxSuffixChars, fb)
  if not ctx then return end
  -- AX hasn't seen the keystroke yet: re-read shortly rather than reuse/fetch
  -- against the old text. ponytail: 4×40 ms, then proceed anyway — an app that
  -- rewrites the char (smart quotes ' → ’) never "catches up".
  attempt = attempt or 0
  if not suggestion.caughtUp(ctx.prefix, typedTail) and attempt < 4 then
    debounceTimer = hs.timer.doAfter(0.04, function()
      debounceTimer = nil
      requestSuggestion(app, attempt + 1)
    end)
    return
  end
  if #ctx.prefix < (config.minPrefixChars or 3) then
    logPredict(app:name(), ctx.prefix, "suppress", "min-prefix")
    return
  end

  if reuseSuggestion(ctx, app:name()) then return end  -- served locally, no request needed

  local requestedPrefix = ctx.prefix
  local requestedSuffix = ctx.afterCursor or ""
  -- Send a clean word boundary to the model — a trailing space derails base
  -- models — then reconcile the space back on the candidate side so insertion
  -- isn't double-spaced. requestedPrefix stays untrimmed for staleness/reuse.
  local promptText, didTrim = suggestion.trimPromptEnd(requestedPrefix)
  -- Frame with the document title (Obsidian-plugin port). Applied to the PROMPT
  -- only: requestedPrefix stays raw because reuseSuggestion and the stale-caret
  -- check below compare against it, and framing it would make every comparison
  -- miss. `title` is the window title already read for the site filter, so this
  -- costs no extra AX call.
  if config.contextTitle then
    promptText = suggestion.titleFrame(appName, title) .. promptText
  end
  activeReqId = activeReqId + 1
  local reqId = activeReqId
  local task
  task = completion.request(config, promptText, requestedSuffix,
    function(rawText)
      if reqId ~= activeReqId or activeReqTask ~= task then return end
      activeReqTask = nil
      local text = suggestion.reconcileLeadingSpace(cleanSuggestion(rawText), didTrim)
      if text == "" then
        logPredict(app:name(), requestedPrefix, "suppress", "empty")
        return
      end
      -- The caret may have moved while the request was in flight — only
      -- show the suggestion if the prefix it was computed for still matches.
      local fresh = caret.getFocusedContext(app, config.maxPrefixChars, config.maxSuffixChars, fb)
      if not fresh or fresh.prefix ~= requestedPrefix then
        logPredict(app:name(), requestedPrefix, "suppress", "stale")
        return
      end
      showSuggestion(fresh.rect, text, requestedPrefix)
      logPredict(app:name(), requestedPrefix, "shown", text)
    end,
    function(err)
      if reqId ~= activeReqId or activeReqTask ~= task then return end
      activeReqTask = nil
      -- A single missed suggestion stays silent — never interrupt typing. But a
      -- connection failure means the server is down, which we do surface (once)
      -- and recover from automatically.
      if type(err) == "string" and err:sub(1, 9) == "curl exit" then
        logPredict(app:name(), requestedPrefix, "suppress", "server-down")
        markServerDown()
      end
    end
  )
  activeReqTask = task
end

local function scheduleSuggestion(app)
  cancelPending()
  debounceTimer = hs.timer.doAfter((config.idleMs or 220) / 1000, function()
    debounceTimer = nil
    requestSuggestion(app)
  end)
end

-- ── Server lifetime ───────────────────────────────────────────────────────────
-- The launchd agent is RunAtLoad=false and has no KeepAlive: GhostType owns the
-- MLX server's lifetime, so ~500MB of model is not resident while GhostType is
-- off. Not one `launchctl <verb>` helper: the CLI is asymmetric — `kickstart`
-- takes a domain-qualified target while legacy `stop` wants a bare label and
-- exits 3 (silently doing nothing) if given one. `kill` is the domain-qualified
-- counterpart, and with no KeepAlive the job stays idle afterwards.
local SERVICE = "gui/$(id -u)/com.local.ghosttype-server"
local function startServer() hs.execute("launchctl kickstart " .. SERVICE) end
local function stopServer()  hs.execute("launchctl kill SIGTERM " .. SERVICE) end

-- The spellcheck server is a second, independent service (port 8791). It shares
-- the master switch so one toggle silences every GhostType surface, but it is
-- started separately: it holds a different backend and must not take the FIM
-- server down with it if it fails to boot.
local SPELL_SERVICE = SERVICE:gsub("ghosttype%-server$", "ghosttype-spellcheck")
local function startSpellServer() hs.execute("launchctl kickstart " .. SPELL_SERVICE) end
local function stopSpellServer()  hs.execute("launchctl kill SIGTERM " .. SPELL_SERVICE) end

-- ── Toggle hotkey ─────────────────────────────────────────────────────────────
-- Single enable/disable path shared by the ⌘⌥G hotkey, the menubar toggle,
-- AND the settings window's header switch (which applies instantly, not on
-- Save — so all three stay in sync by construction). Does NOT touch the
-- eventtap or Tab/Escape gating (DEC-003) — it only flips config.enabled;
-- handleEvent already early-returns when config.enabled is false.
local function setEnabled(v)
  config.enabled = v == true
  cfg_mod.save(config)
  if config.enabled then
    startServer()
    startSpellServer()
  else
    cancelPending()
    forgetSuggestion()
    stopServer()
    stopSpellServer()
  end
  menubar.setEnabled(config.enabled)
  hs.alert.show("GhostType: " .. (config.enabled and "on" or "off"), { textSize = 13 }, 1.2)
end

-- Exposed so the server-lifetime behaviour is checkable without synthesising a
-- keystroke: `hs -c 'require("ghosttype").setEnabled(true)'`. Same path as the
-- hotkey, so a passing check is a real check. See tests/check_server_lifetime.sh.
M.setEnabled = setEnabled

local function toggleEnabled()
  setEnabled(not config.enabled)
end

local function registerHotkeys()
  if toggleHotkeyBind then toggleHotkeyBind:delete() end
  local hk = config.toggleHotkey
  toggleHotkeyBind = hs.hotkey.bind(hk.mods, hk.key, toggleEnabled)

  -- Spellcheck rides the same master switch as completion: when GhostType is
  -- off the hotkey stays bound but does nothing, so the panel can never appear
  -- over text the user has deliberately switched GhostType away from.
  if checkHotkeyBind then checkHotkeyBind:delete(); checkHotkeyBind = nil end
  local ck = config.checkHotkey
  if ck and ck.key then
    checkHotkeyBind = hs.hotkey.bind(ck.mods, ck.key, function()
      if config.enabled then spellcheck.check() else spellcheck.hide() end
    end)
  end
  if checkDeepHotkeyBind then checkDeepHotkeyBind:delete(); checkDeepHotkeyBind = nil end
  local cd = config.checkDeepHotkey
  if cd and cd.key and config.spellDeepModel then
    checkDeepHotkeyBind = hs.hotkey.bind(cd.mods, cd.key, function()
      if config.enabled then spellcheck.check({ model = config.spellDeepModel }) else spellcheck.hide() end
    end)
  end

  -- The probe answers "could GhostType work here?" and is deliberately NOT
  -- gated on config.enabled or on the app being listed — measuring an app you
  -- have not enabled yet is the entire point.
  if probeHotkeyBind then probeHotkeyBind:delete(); probeHotkeyBind = nil end
  local pk = config.probeHotkey
  if pk and pk.key then
    probeHotkeyBind = hs.hotkey.bind(pk.mods, pk.key, function() pcall(probe.run) end)
  end
end

-- ── Settings window ───────────────────────────────────────────────────────────
-- applySettings mutates `config` (the same table everything reads), so most
-- changes are live the moment the save lands; only the hotkey needs an
-- explicit re-register, and one bad save must never break GhostType (pcall).
local function openSettings()
  settings.open(config, {
    onSetEnabled = setEnabled, -- header switch applies instantly via the shared path
    onSaved = function(warnings)
      cfg_mod.save(config)
      local okHK = pcall(registerHotkeys)
      menubar.setEnabled(config.enabled)
      local msg = "Settings saved"
      if not okHK then msg = msg .. " — hotkey could not be registered" end
      if warnings and #warnings > 0 then
        msg = msg .. " — " .. table.concat(warnings, "; ")
      end
      hs.notify.new({ title = "GhostType", informativeText = msg }):send()
    end,
  })
end

-- ── Event tap ─────────────────────────────────────────────────────────────────
-- One tap handles suggestion triggering (keyDown), acceptance (Tab = word, § = all),
-- dismissal (Escape / click / scroll). We never swallow a key unless a
-- suggestion is actually visible, so normal Tab-navigation and Escape
-- behavior in every app is completely unaffected when GhostType has
-- nothing to show.
local function isIgnoredNavigationKey(keyCode)
  local map = hs.keycodes.map
  local ignored = {
    map.tab, map.escape,
    map.left, map.right, map.up, map.down,
    map.home, map["end"], map.pageup, map.pagedown,
  }
  for _, code in ipairs(ignored) do
    if code and keyCode == code then return true end
  end
  return false
end

local function isEditKey(keyCode)
  local map = hs.keycodes.map
  local editKeys = { map.delete, map.forwarddelete, map["return"], map.padenter, map.space }
  for _, code in ipairs(editKeys) do
    if code and keyCode == code then return true end
  end
  return false
end

local function shouldScheduleAfterKey(event, keyCode, flags)
  -- Do not fire completions for app/menu shortcuts or navigation. Shift is okay:
  -- it is how users type uppercase and symbols.
  if flags.cmd or flags.alt or flags.ctrl then return false end
  if isIgnoredNavigationKey(keyCode) then return false end
  if isEditKey(keyCode) then return true end

  local ok, chars = pcall(function() return event:getCharacters() end)
  if not ok or type(chars) ~= "string" or chars == "" then return false end
  if chars == "\t" or chars == "\27" or chars == "\127" then return false end
  return true
end

local function handleEvent(event)
  if not config.enabled then return false end

  local frontApp = hs.application.frontmostApplication()
  local appName = frontApp and frontApp:name()
  if not profiles.isEnabledFor(config, appName) then
    forgetSuggestion()
    return false
  end

  local etype = event:getType()
  local types = hs.eventtap.event.types

  if etype == types.keyDown then
    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    local noMods = not (flags.cmd or flags.alt or flags.ctrl or flags.shift)

    -- Tab accepts one word, keeping the rest as ghost (swapped with § 2026-09-17).
    if currentSuggestion and keyCode == hs.keycodes.map.tab and noMods then
      local chunk, rest = suggestion.nextChunk(currentSuggestion)
      if chunk then
        acceptWord(chunk, rest, frontApp)
        return true -- swallow: consumed as "accept word"
      end
    end

    if currentSuggestion and keyCode == hs.keycodes.map.escape then
      forgetSuggestion()
      return true -- swallow: consumed as "dismiss"
    end

    -- § accepts the whole suggestion (matches the Obsidian plugin).
    if currentSuggestion and noMods then
      local okCh, ch = pcall(function() return event:getCharacters() end)
      if okCh and ch == "§" then
        local text = currentSuggestion
        forgetSuggestion()
        -- Without this every replayed keystroke scheduled a fetch against a
        -- half-inserted buffer. ponytail: fixed 0.5 s window, too short for
        -- slow Electron replays; hig-redesign polls insertionLanded instead.
        cancelPending()
        suppressUntil = hs.timer.secondsSinceEpoch() + 0.5
        logPredict(frontApp and frontApp:name() or "?", "", "accepted", text)
        caret.insertText(text)
        return true -- swallow the §
      end
    end

    -- Replayed synthetic keystrokes from an accept: let them through to the
    -- app untouched — no soft-hide, no refetch. The remainder ghost stays put.
    if hs.timer.secondsSinceEpoch() < suppressUntil then return false end

    -- Soft hide only: keep the remembered suggestion so the upcoming debounce
    -- can trim-and-reuse it if this keystroke matches its next character.
    if currentSuggestion then clearSuggestion() end
    if shouldScheduleAfterKey(event, keyCode, flags) then
      typedTail = nil
      if keyCode == hs.keycodes.map.space or not isEditKey(keyCode) then
        local okC, c = pcall(function() return event:getCharacters() end)
        if okC and type(c) == "string" and c ~= "" then typedTail = c end
      end
      scheduleSuggestion(frontApp)
    else
      cancelPending()
    end
    return false

  elseif etype == types.leftMouseDown or etype == types.scrollWheel then
    cancelPending()
    forgetSuggestion()
    return false
  end

  return false
end

local function startTap()
  if tap then tap:stop() end
  local types = hs.eventtap.event.types
  tap = hs.eventtap.new({ types.keyDown, types.leftMouseDown, types.scrollWheel }, handleEvent)
  tap:start()
  -- hs.eventtap objects are collected (and silently stop delivering events) if
  -- nothing reachable from a GC root holds them. The module-local `tap` upvalue
  -- is not rooted (M is returned empty), so pin it on M, which package.loaded
  -- keeps alive for the process lifetime. Without this the tap dies on the first
  -- GC after load and no suggestions ever fire.
  M.tap = tap
end

-- Clears state on app switch so a suggestion never lingers over the wrong app.
-- Also pre-warms tier-2 (Chromium/Electron) apps: the first AX query after a
-- window switch is what forces Chromium to build its accessibility tree, so
-- pay that cost with a throwaway read now instead of on the first real pause.
local function startAppWatcher()
  if appWatcher then appWatcher:stop() end
  appWatcher = hs.application.watcher.new(function(_name, eventType, app)
    if eventType == hs.application.watcher.activated then
      cancelPending()
      forgetSuggestion()
      local p = app and config.apps and config.apps[app:name()]
      if p and p.enabled and p.tier == 2 then
        local pid = app:pid()
        hs.timer.doAfter(0.2, function()
          -- Re-check the same app is still frontmost — a rapid switch away
          -- means no AX work against a background app, no state touched.
          local front = hs.application.frontmostApplication()
          if not front or front:pid() ~= pid then return end
          local fb = { charWidth = config.fallbackCharWidth, lineHeight = config.fallbackLineHeight, leftPad = config.fallbackLeftPad }
          caret.getFocusedContext(app, 1, 0, fb) -- result discarded; tree is warm now
        end)
      end
    end
  end)
  appWatcher:start()
  M.appWatcher = appWatcher  -- root it too (same GC footgun as the eventtap)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
logmod.reset()  -- fresh prediction log each launch
spellcheck.setup(config, logmod)
menubar.setup({
  onToggle   = toggleEnabled,
  onOpenLog  = function() os.execute('open "' .. logmod.LOG_PATH .. '"') end,
  onOpenProbeLog = function() os.execute('open "' .. probe.LOG_PATH .. '"') end,
  onReload   = function() hs.reload() end,
  onSettings = openSettings,
  statsUrl   = config.serverUrl, -- Obsidian tally line reads <server>/stats on menu open
})
menubar.setEnabled(config.enabled)
if not pcall(registerHotkeys) then
  hs.notify.new({ title = "GhostType",
    informativeText = "Toggle hotkey in config is invalid — fix it in Settings" }):send()
end
startTap()
startAppWatcher()

-- Start the server only when we come up enabled — Hammerspoon's launch IS
-- "opening the app". When GhostType is off there is nothing to check and
-- nothing to warn about, so no login-time notification either.
if config.enabled then
  startServer()
  startSpellServer()
  completion.checkServer(config, function(up)
    -- We just kickstarted it, so a miss here means "still booting", not
    -- "broken": poll quietly instead of crying wolf. A request that fails
    -- later still routes through markServerDown and does notify.
    if not up then startRecheck() end
  end)
end

local hk = config.toggleHotkey
hs.notify.new({
  title = "GhostType",
  informativeText = "Ready - " .. table.concat(hk.mods or {}, "+") .. "+" .. (hk.key or "g") .. " to toggle"
}):send()

return M
