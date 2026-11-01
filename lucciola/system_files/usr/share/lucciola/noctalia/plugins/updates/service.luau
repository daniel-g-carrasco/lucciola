--!nonstrict
-- Updates service: the only entry that runs update-state. Every minute it
-- publishes the result through noctalia.state (up.ready, up.booted,
-- up.staged, up.working, up.failed, up.failed_titles, up.failed_line) for
-- the indicator; a refresh can be asked at once:
--
--   noctalia msg plugin lucciola/updates:service all refresh

noctalia.setUpdateInterval(60000)

local function command()
  local candidates = {
    noctalia.getConfig("command"),
    "/usr/libexec/lucciola/update-state",
  }
  for _, c in candidates do
    if c and c ~= "" then
      local p = noctalia.expandPath(c)
      if noctalia.fileExists(p) then
        return p
      end
    end
  end
  return nil
end

local function refresh()
  local cmd = command()
  if not cmd then
    noctalia.state.set("up.ready", false)
    return
  end
  noctalia.runAsync({ cmd, "--json" }, function(r)
    if r.exitCode ~= 0 then
      noctalia.log(`update-state failed: {r.stderr}`)
      return
    end
    local s = noctalia.json.decode(r.stdout)
    if type(s) ~= "table" then
      return
    end
    local titles, line = {}, ""
    for _, ch in (s.channels or {}) do
      if ch.outcome == "failed" or ch.outcome == "hung" then
        table.insert(titles, ch.title)
        if line == "" then
          line = ch.line or ""
        end
      end
    end
    noctalia.state.set("up.booted", s.booted or "")
    noctalia.state.set("up.staged", s.staged or "")
    noctalia.state.set("up.working", (s.transaction or "") ~= "")
    noctalia.state.set("up.failed", s.failed or 0)
    noctalia.state.set("up.failed_titles", table.concat(titles, ", "))
    noctalia.state.set("up.failed_line", line)
    noctalia.state.set("up.ready", true)
  end)
end

function update()
  refresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end

refresh()
