-- Minimal Hammerspoon stub for host-free GhostType unit tests.
local hs = _G.hs or {}

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = deepCopy(val) end
  return out
end

hs._jsonFixtures = hs._jsonFixtures or {}
hs.json = hs.json or {}
function hs.json.encode(v) return deepCopy(v) end
function hs.json.decode(v)
  if type(v) == "table" then return deepCopy(v) end
  if hs._jsonFixtures[v] ~= nil then return deepCopy(hs._jsonFixtures[v]) end
  error("hs_stub cannot decode arbitrary JSON string: " .. tostring(v))
end

hs.fs = hs.fs or {}
function hs.fs.attributes(_) return nil end
function hs.fs.mkdir(_) return true end

hs.timer = hs.timer or {}
function hs.timer.doAfter(_, fn) if fn then fn() end; return { stop = function() end } end

hs.notify = hs.notify or {}
function hs.notify.new(_) return { send = function() end } end

hs.keycodes = hs.keycodes or { map = {} }
hs.keycodes.map = hs.keycodes.map or {
  tab = 48, escape = 53,
  left = 123, right = 124, down = 125, up = 126,
  home = 115, ["end"] = 119, pageup = 116, pagedown = 121,
  delete = 51, forwarddelete = 117, returnkey = 36, ["return"] = 36,
  padenter = 76, space = 49,
}

_G.hs = hs
return hs
