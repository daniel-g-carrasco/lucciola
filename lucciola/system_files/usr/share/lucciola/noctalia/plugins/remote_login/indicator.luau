--!nonstrict
-- Remote Login bar indicator: shown only while remote login is on (a warning
-- glyph if it is open to every network, the old way), hidden otherwise.
-- Click opens the panel; right click turns it off.

local common = require("./lib/common.luau")

local function render()
  local s = common.snapshot()
  if not common.isOn(s) then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setText("")
  if s.state == "everyone" then
    barWidget.setGlyph(common.GLYPH_WARN)
    barWidget.setGlyphColor("error")
    barWidget.setTooltip({ { noctalia.tr("tooltip.title"), noctalia.tr("tooltip.everyone") } })
    return
  end
  barWidget.setGlyph(common.GLYPH_ON)
  barWidget.setGlyphColor("primary")
  local who = common.who(s)
  barWidget.setTooltip({
    { noctalia.tr("tooltip.title"), noctalia.tr("tooltip.on") },
    { noctalia.tr("tooltip.who"), who ~= "" and who or noctalia.tr("who.nobody") },
  })
end

common.watch(render)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(common.PANEL)
end

function onRightClick()
  common.send("off")
end
