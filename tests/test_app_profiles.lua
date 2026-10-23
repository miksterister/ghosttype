package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local profiles = require("app_profiles")

local cfg = {
  enabled = true,
  apps = {
    Notes = { enabled = true, tier = 1 },
    Obsidian = { enabled = false, tier = 3 },
  },
}

T.eq(profiles.isEnabledFor(cfg, "Notes"), true, "enabled app")
T.eq(profiles.isEnabledFor(cfg, "Obsidian"), false, "disabled app")
T.eq(profiles.isEnabledFor(cfg, "Unknown"), false, "unknown app")
T.eq(profiles.isEnabledFor({ enabled = false, apps = cfg.apps }, "Notes"), false, "master disabled")
T.eq(profiles.isEnabledFor({ enabled = true }, "Notes"), false, "missing apps table")
T.eq(profiles.isEnabledFor(cfg, nil), false, "nil app name")

-- siteAllowed: site filter, URL primary + window-title fallback (DEC-005).
-- Named AI-chat conversations title the tab with just the conversation name,
-- so the URL is the signal that actually works; title covers new-tab pages
-- and the no-Automation-permission fallback.
local cfg2 = {
  enabled = true,
  apps = {
    Arc     = { enabled = true, tier = 2,
                titlePatterns = { "Claude", "ChatGPT", "Gemini" },
                sitePatterns  = { "claude.ai", "chatgpt.com", "gemini.google.com" } },
    Vivaldi = { enabled = true, tier = 2, titlePatterns = {}, sitePatterns = {} },
    Notes   = { enabled = true, tier = 1 },
  },
}
T.eq(profiles.siteAllowed(cfg2, "Notes", "Anything At All", nil), true, "no patterns: any title allowed")
T.eq(profiles.siteAllowed(cfg2, "Notes", nil, nil), true, "no patterns: nil title+url allowed")
T.eq(profiles.siteAllowed(cfg2, "Vivaldi", "Random Form", "https://example.com"), true, "empty pattern lists: allowed")
T.eq(profiles.siteAllowed(cfg2, "Arc", "workout routine plan", "https://claude.ai/chat/7b98bcbf"), true, "named conversation: URL matches, title doesn't")
T.eq(profiles.siteAllowed(cfg2, "Arc", "New chat - Claude", nil), true, "nil URL: title fallback matches")
T.eq(profiles.siteAllowed(cfg2, "Arc", "GitHub - some/repo", "https://github.com/x"), false, "neither matches: blocked")
T.eq(profiles.siteAllowed(cfg2, "Arc", nil, nil), false, "nil title+url fails closed with patterns")
T.eq(profiles.siteAllowed(cfg2, "Arc", "chatgpt", "https://CHATGPT.example"), false, "match is case-sensitive both ways")

T.finish("app_profiles")
