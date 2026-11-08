--!nonstrict
-- Remote Login control-centre tile: click turns it on or off (the system asks
-- for the password or the fingerprint), right click opens the panel.

local common = require("./lib/common.luau")

local function render()
  local s = common.snapshot()
  shortcut.setIcon(common.GLYPH_ON, common.GLYPH_OFF)
  shortcut.setActive(common.isOn(s))
  shortcut.setEnabled(s.ready and not s.busy and s.state ~= "unknown")
  shortcut.setLabel(noctalia.tr("tile.label"))
end

common.watch(render)
render()

function onClick()
  common.send(common.isOn(common.snapshot()) and "off" or "on")
end

function onRightClick()
  noctalia.togglePanel(common.PANEL)
end
