-- GhostType · app_profiles.lua
-- Thin wrapper around cfg.apps so the rest of the code doesn't reach into
-- the config table shape directly. See config.lua for the tier meanings.

local M = {}

function M.isEnabledFor(cfg, appName)
  if not cfg.enabled then return false end
  local p = cfg.apps and appName and cfg.apps[appName]
  return p ~= nil and p.enabled == true
end

-- Site filter (DEC-005): allowed when the tab URL contains a `sitePatterns`
-- entry OR the window title contains a `titlePatterns` entry (plain substring,
-- case-sensitive). URL is the primary signal — named Claude/ChatGPT
-- conversations title the tab with just the conversation name, so titles only
-- identify new-tab pages — and the title is the fallback for when AppleScript
-- can't supply a URL (Automation permission not yet granted). No patterns of
-- either kind = fire everywhere. nil title/url fail closed for gated apps.
function M.siteAllowed(cfg, appName, windowTitle, url)
  local p = cfg.apps and appName and cfg.apps[appName]
  local sites, titles = p and p.sitePatterns, p and p.titlePatterns
  local hasSites  = type(sites)  == "table" and #sites  > 0
  local hasTitles = type(titles) == "table" and #titles > 0
  if not hasSites and not hasTitles then return true end
  if hasSites and type(url) == "string" then
    for _, pat in ipairs(sites) do
      if url:find(pat, 1, true) then return true end
    end
  end
  if hasTitles and type(windowTitle) == "string" then
    for _, pat in ipairs(titles) do
      if windowTitle:find(pat, 1, true) then return true end
    end
  end
  return false
end

return M
