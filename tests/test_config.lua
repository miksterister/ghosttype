package.path = "./?.lua;./tests/?.lua;" .. package.path
local hs = require("hs_stub")
local T = require("testlib")
local cfg_mod = require("config")

-- Missing config returns a deep copy of defaults.
cfg_mod.CONFIG_PATH = "/tmp/ghosttype-test-missing.json"
local cfg = cfg_mod.load()
T.eq(cfg.enabled, true, "default enabled")
T.eq(cfg.model, "mlx-community/Qwen2.5-Coder-1.5B-4bit", "default coder model")
T.eq(cfg.apps["Notes"].enabled, true, "default notes enabled")

-- Existing config gets newly added defaults merged while preserving overrides.
hs._jsonFixtures.CUSTOM_CFG = {
  enabled = true,
  apps = {
    ["Notes"] = { enabled = false },
    ["Custom Writer"] = { enabled = true, tier = 9 },
  },
}
cfg_mod.readFile = function(_) return "CUSTOM_CFG" end
local merged = cfg_mod.load()
T.eq(merged.apps["Notes"].enabled, false, "preserve app override")
T.eq(merged.apps["Notes"].tier, 1, "merge missing app field")
T.eq(merged.apps["Mail"].enabled, true, "add missing default app")
T.eq(merged.apps["Custom Writer"].enabled, true, "preserve custom app")
T.eq(merged.serverUrl, "http://127.0.0.1:8790", "merge missing top-level default")

-- copyMissing must not resurrect deleted list entries / regrow shortened lists.
hs._jsonFixtures.SHORTENED_CFG = {
  enabled = true,
  toggleHotkey = { mods = { "ctrl" }, key = "g" },
  apps = {
    ["Arc"] = { enabled = true, tier = 2, sitePatterns = { "claude.ai" } },
  },
}
cfg_mod.readFile = function(_) return "SHORTENED_CFG" end
local shortened = cfg_mod.load()
T.eq(#shortened.apps["Arc"].sitePatterns, 1, "shortened pattern list survives merge")
T.eq(#shortened.toggleHotkey.mods, 1, "shortened hotkey mods survive merge")

T.finish("config")
