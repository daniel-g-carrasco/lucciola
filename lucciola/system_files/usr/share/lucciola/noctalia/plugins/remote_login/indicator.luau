--!nonstrict
-- Remote Login bar indicator. Always there: lit (primary) while remote login
-- is on, a warning glyph if it is open to every network (the old way), dim
-- when it is off. It used to hide when off, which left nothing to turn it
-- back on with (2026-11-14). Click opens the panel; right click turns it on
-- or off.

local common = require("./lib/common.luau")

local function render()
  local s = common.snapshot()
  barWidget.setVisible(true)
  barWidget.setText("")
  if not common.isOn(s) then
    barWidget.setGlyph(common.GLYPH_OFF)
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip({
      { noctalia.tr("tooltip.title"), noctalia.tr("tooltip.off") },
      { noctalia.tr("tooltip.hint_label"), noctalia.tr("tooltip.hint_on") },
    })
    return
  end
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
    { noctalia.tr("tooltip.hint_label"), noctalia.tr("tooltip.hint_off") },
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
  common.send(common.isOn(common.snapshot()) and "off" or "on")
end
