--!nonstrict
-- Remote Login service: the only entry that runs commands. It polls
-- `remote-login status --json` into noctalia.state (rl.status, rl.ready) and
-- runs what the other entries publish on rl.cmd: on and off through pkexec
-- and the privileged helper, "manage" opens Lucciola System on its Login page.
--
--   noctalia msg plugin lucciola/remote_login:service all refresh

noctalia.setUpdateInterval(10000)

local ADMIN = "/usr/libexec/lucciola/admin"
local SYSTEM = "/usr/libexec/margine/system-gui"

local function command()
  local c = noctalia.getConfig("command")
  for _, p in { c, "/usr/libexec/lucciola/remote-login" } do
    if p and p ~= "" and noctalia.fileExists(noctalia.expandPath(p)) then
      return noctalia.expandPath(p)
    end
  end
  return nil
end

local function refresh()
  local cmd = command()
  if not cmd then
    noctalia.state.set("rl.ready", false)
    return
  end
  noctalia.runAsync({ cmd, "status", "--json" }, function(r)
    if r.exitCode ~= 0 then
      noctalia.log(`remote-login status failed: {r.stderr}`)
      return
    end
    noctalia.state.set("rl.status", r.stdout)
    noctalia.state.set("rl.ready", true)
  end)
end

function update()
  refresh()
end

noctalia.state.watch("rl.cmd", function(raw)
  local req = raw and noctalia.json.decode(raw)
  if type(req) ~= "table" then
    return
  end
  if req.action == "manage" then
    noctalia.runAsync({ SYSTEM, "--page", "login" }, function(_r) end)
    return
  end
  local verb = req.action == "on" and "ssh-on" or req.action == "off" and "ssh-off" or nil
  if not verb then
    return
  end
  noctalia.state.set("rl.busy", true)
  noctalia.runAsync({ "pkexec", ADMIN, verb }, function(r)
    noctalia.state.set("rl.busy", false)
    -- 126/127 with nothing said: the authentication was dismissed.
    if r.exitCode ~= 0 and not ((r.exitCode == 126 or r.exitCode == 127) and noctalia.string.trim(r.stderr or "") == "") then
      noctalia.notifyError(noctalia.tr("error.title"), noctalia.string.trim(r.stderr or r.stdout or ""))
    end
    refresh()
  end)
end)

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end

refresh()
