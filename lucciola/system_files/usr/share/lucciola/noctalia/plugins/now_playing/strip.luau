--!nonstrict
-- Now Playing strip for the lock screen: cover, title and artist, and three
-- controls on one row. It asks /usr/libexec/lucciola/now-playing every three
-- seconds while it is on screen (update() ticks only then), and right after
-- a control is pressed. Nothing playing: nothing drawn.

-- The strip is the password field's twin: as wide (392, measured on the lock
-- screen), the same corner radius and the same dark fill.
local WIDTH = 392
local COVER = 40
local PAD = 10
local POLL_EVERY = 3

local state = { active = false }
local ticks = 0
local asking = false

local function command()
  for _, c in { noctalia.getConfig("command"), "/usr/libexec/lucciola/now-playing" } do
    if c and c ~= "" then
      local p = noctalia.expandPath(c)
      if noctalia.fileExists(p) then
        return p
      end
    end
  end
  return nil
end

local render

local function refresh()
  local cmd = command()
  if not cmd or asking then
    return
  end
  asking = true
  noctalia.runAsync({ cmd, "status" }, function(r)
    asking = false
    local s = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    state = type(s) == "table" and s or { active = false }
    render()
  end)
end

local function send(verb)
  local cmd = command()
  if not cmd or not state.player then
    return
  end
  noctalia.runAsync({ cmd, verb, state.player }, function(_r)
    refresh()
  end)
end

local function control(glyph, verb, size)
  return ui.button({
    glyph = glyph,
    glyphSize = size,
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      send(verb)
    end,
  })
end

render = function()
  if not state.active then
    desktopWidget.render(ui.row({ width = 0, height = 0 }, {}))
    return
  end
  local cover
  if state.art and state.art ~= "" then
    cover = ui.image({ path = state.art, width = COVER, height = COVER, radius = 6, fit = "cover" })
  else
    cover = ui.row({ width = COVER, height = COVER, radius = 6, fill = "surface_variant/0.6", align = "center", justify = "center" }, {
      ui.glyph({ name = "music", size = 18, color = "on_surface_variant" }),
    })
  end
  local playing = state.status == "Playing"
  desktopWidget.render(ui.row({ gap = 12, align = "center", width = WIDTH, height = COVER + PAD * 2, padding = PAD, fill = "surface/0.5", radius = 12 }, {
    cover,
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = state.title ~= "" and state.title or "…", fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = state.artist or "", fontSize = 12, color = "on_surface_variant", maxLines = 1, visible = (state.artist or "") ~= "" }),
    }),
    ui.row({ gap = 0, align = "center" }, {
      control("player-skip-back", "previous", 16),
      control(playing and "player-pause" or "player-play", "toggle", 18),
      control("player-skip-forward", "next", 16),
    }),
  }))
end

function update()
  desktopWidget.setWantsSecondTicks(true)
  if ticks % POLL_EVERY == 0 then
    refresh()
  end
  ticks += 1
end

update()
render()
