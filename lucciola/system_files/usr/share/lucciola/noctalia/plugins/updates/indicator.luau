--!nonstrict
-- Updates bar indicator. Hidden while nothing wants a look; a lit download
-- glyph while a new version is staged (restart to finish), a refresh glyph
-- while rpm-ostreed works, a red warning glyph while an automatic update
-- failed or hung (the failure wins over the rest). Click opens Lucciola
-- System on the Overview.

local GLYPH_STAGED = "download"
local GLYPH_WORKING = "refresh"
local GLYPH_FAILED = "alert-triangle"

local function snapshot()
  return {
    ready = noctalia.state.get("up.ready") == true,
    booted = noctalia.state.get("up.booted") or "",
    staged = noctalia.state.get("up.staged") or "",
    working = noctalia.state.get("up.working") == true,
    failed = noctalia.state.get("up.failed") or 0,
    failedTitles = noctalia.state.get("up.failed_titles") or "",
    failedLine = noctalia.state.get("up.failed_line") or "",
  }
end

local function render()
  local s = snapshot()
  local showVersion = noctalia.getConfig("show_version") == true
  local rows = {}
  if not s.ready then
    barWidget.setVisible(false)
    return
  end
  if s.failed > 0 then
    barWidget.setVisible(true)
    barWidget.setGlyph(GLYPH_FAILED)
    barWidget.setGlyphColor("error")
    barWidget.setColor("error")
    barWidget.setText("")
    table.insert(rows, { noctalia.tr("tooltip.failed"), s.failedTitles })
    if s.failedLine ~= "" then
      table.insert(rows, { noctalia.tr("tooltip.reason"), s.failedLine })
    end
  elseif s.working then
    barWidget.setVisible(true)
    barWidget.setGlyph(GLYPH_WORKING)
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setColor("on_surface_variant")
    barWidget.setText("")
    table.insert(rows, { noctalia.tr("tooltip.title"), noctalia.tr("tooltip.working") })
  elseif s.staged ~= "" then
    barWidget.setVisible(noctalia.getConfig("show_staged") ~= false)
    barWidget.setGlyph(GLYPH_STAGED)
    barWidget.setGlyphColor("primary")
    barWidget.setColor("primary")
    barWidget.setText(showVersion and s.staged or "")
    table.insert(rows, { noctalia.tr("tooltip.title"), noctalia.tr("tooltip.staged", { version = s.staged }) })
    table.insert(rows, { noctalia.tr("tooltip.running"), s.booted })
  else
    barWidget.setVisible(false)
    return
  end
  table.insert(rows, { noctalia.tr("tooltip.open"), "" })
  barWidget.setTooltip(rows)
end

for _, key in { "up.ready", "up.booted", "up.staged", "up.working", "up.failed", "up.failed_titles", "up.failed_line" } do
  noctalia.state.watch(key, render)
end

function update()
  render()
end

local function open()
  local cmd = noctalia.getConfig("open_command") or "gtk-launch dev.margine.System"
  local argv = {}
  for word in string.gmatch(cmd, "%S+") do
    table.insert(argv, word)
  end
  if #argv == 0 then
    return
  end
  noctalia.runAsync(argv, function(r)
    if r.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("error.title"), noctalia.string.trim(r.stderr or ""))
    end
  end)
end

function onClick()
  open()
end

function onRightClick()
  open()
end

render()
