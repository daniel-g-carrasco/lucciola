--!nonstrict
-- Remote Login panel: the state with its switch, who may come in (your own
-- WireGuard tunnels, the chosen devices), how to reach this computer, and
-- Lucciola System's Login page to add or remove devices. Lists are capped so
-- the panel never grows past its height.

local common = require("./lib/common.luau")

local MAX_ROWS = 4

local function statusBlock(s)
  local title, detail, color, glyph
  if s.state == "on" then
    title, color, glyph = noctalia.tr("panel.on"), "primary", common.GLYPH_ON
    local who = common.who(s)
    detail = who ~= "" and noctalia.tr("panel.on_detail", { who = who }) or noctalia.tr("who.nobody")
  elseif s.state == "everyone" then
    title, color, glyph = noctalia.tr("panel.everyone"), "error", common.GLYPH_WARN
    detail = noctalia.tr("panel.everyone_detail")
  elseif s.state == "blocked" then
    title, color, glyph = noctalia.tr("panel.blocked"), "error", common.GLYPH_WARN
    detail = noctalia.tr("panel.blocked_detail")
  elseif s.state == "off" then
    title, color, glyph = noctalia.tr("panel.off"), "on_surface_variant", common.GLYPH_OFF
    detail = noctalia.tr("panel.off_detail")
  else
    title, color, glyph = noctalia.tr("panel.unknown"), "on_surface_variant", common.GLYPH_OFF
    detail = noctalia.tr("panel.unknown_detail")
  end
  local on = common.isOn(s)
  return ui.column({ gap = 10, padding = 12, fill = "surface_variant/0.4", radius = 10 }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = glyph, size = 22, color = color }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = color }),
        ui.label({ text = detail, fontSize = 12, color = "on_surface_variant", wrap = true }),
      }),
      ui.button({
        text = noctalia.tr(on and "panel.turn_off" or "panel.turn_on"),
        variant = on and "destructive" or "primary",
        controlSize = "sm",
        enabled = s.ready and not s.busy and s.state ~= "unknown",
        onClick = function()
          common.send(on and "off" or "on")
        end,
      }),
    }),
  })
end

local function line(glyph, text, sub)
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = glyph, size = 16, color = "secondary" }),
    ui.label({ text = text, fontSize = 13, flexGrow = 1, wrap = true }),
    ui.label({ text = sub or "", fontSize = 12, color = "on_surface_variant", visible = (sub or "") ~= "" }),
  })
end

local function whoBlock(s)
  local rows = { ui.label({ text = noctalia.tr("panel.who"), fontSize = 13, fontWeight = "bold" }) }
  local shown = 0
  for _, t in common.ownTunnels(s) do
    if shown < MAX_ROWS then
      table.insert(rows, line("route", t.name, t.active and "" or noctalia.tr("panel.not_connected")))
    end
    shown += 1
  end
  for _, d in s.devices do
    if shown < MAX_ROWS then
      table.insert(rows, line("device-desktop", d.name or d.address, d.address))
    end
    shown += 1
  end
  if shown == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.none"), fontSize = 12, color = "on_surface_variant", wrap = true }))
  elseif shown > MAX_ROWS then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.more", { n = shown - MAX_ROWS }), fontSize = 12, color = "on_surface_variant" }))
  end
  return ui.column({ gap = 8 }, rows)
end

local function reachBlock(s)
  if s.state ~= "on" or #s.addresses == 0 then
    return nil
  end
  local rows = { ui.label({ text = noctalia.tr("panel.reach"), fontSize = 13, fontWeight = "bold" }) }
  for i, a in s.addresses do
    if i > 3 then
      break
    end
    table.insert(rows, line("terminal", `ssh {s.user}@{a.address}`, a.interface))
  end
  return ui.column({ gap = 8 }, rows)
end

local function render()
  local s = common.snapshot()
  local children = {
    ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "primary" }),
    statusBlock(s),
    whoBlock(s),
  }
  local reach = reachBlock(s)
  if reach then
    table.insert(children, reach)
  end
  table.insert(children, ui.row({ justify = "end" }, {
    ui.button({ text = noctalia.tr("panel.manage"), variant = "outline", controlSize = "sm", onClick = function()
      common.send("manage")
      noctalia.togglePanel(common.PANEL)
    end }),
  }))
  panel.render(ui.column({ gap = 14, padding = 16 }, children))
end

common.watch(function()
  render()
end)

function onOpen(_context)
  render()
end
