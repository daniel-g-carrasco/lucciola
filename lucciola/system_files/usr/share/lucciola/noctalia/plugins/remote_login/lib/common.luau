--!nonstrict
-- Shared helpers for every Remote Login entry. State comes from the service
-- through noctalia.state; commands go back to it the same way, so only the
-- service runs commands.

local M = {}

M.PANEL = "lucciola/remote_login:panel"
M.GLYPH_ON = "terminal-2"
M.GLYPH_WARN = "alert-triangle"
M.GLYPH_OFF = "terminal"

function M.snapshot()
  local raw = noctalia.state.get("rl.status")
  local s = raw and noctalia.json.decode(raw)
  if type(s) ~= "table" then
    s = {}
  end
  s.state = s.state or "unknown"
  s.tunnels = s.tunnels or {}
  s.devices = s.devices or {}
  s.addresses = s.addresses or {}
  s.ready = noctalia.state.get("rl.ready") == true
  s.busy = noctalia.state.get("rl.busy") == true
  return s
end

-- On in either way: the new one (tunnels and devices) or the old switch's
-- (every network), which the panel asks to redo.
function M.isOn(s)
  return s.state == "on" or s.state == "everyone"
end

function M.ownTunnels(s)
  local out = {}
  for _, t in s.tunnels do
    if t.own then
      table.insert(out, t)
    end
  end
  return out
end

-- "wg-home and 2 devices", or "" when nobody may come in.
function M.who(s)
  local parts = {}
  for _, t in M.ownTunnels(s) do
    table.insert(parts, t.name)
  end
  local n = #s.devices
  if n == 1 then
    table.insert(parts, noctalia.tr("who.one_device"))
  elseif n > 1 then
    table.insert(parts, noctalia.tr("who.devices", { n = n }))
  end
  return table.concat(parts, noctalia.tr("who.and"))
end

-- Send a command to the service: "on", "off", "manage".
function M.send(action)
  noctalia.state.set("rl.cmd", noctalia.json.encode({ action = action, at = os.time() }))
end

function M.watch(fn)
  for _, key in { "rl.status", "rl.ready", "rl.busy" } do
    noctalia.state.watch(key, fn)
  end
end

return M
