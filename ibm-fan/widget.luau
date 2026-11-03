--!nonstrict
-- ibm-fan bar widget — fan glyph + RPM/level readout.
--
-- Declarative render (not setText) because per-state text color is needed and
-- barWidget.setText has no color prop. Color values are theme role names
-- ("error", "primary"); the host resolves them, matching timer/bar.luau.
--
-- Right click cycles the level (the more destructive action wants the
-- deliberate button), left click opens the control panel. Middle click stays
-- the built-in open-settings (no [widget.actions] declared).

local status = noctalia.state.get("fan.status") or { available = false, error = "missing" }
local error_ = noctalia.state.get("fan.error")

local CYCLE = { "auto", "0", "1", "2", "3", "4", "5", "6", "7", "disengaged" }

local function nextLevel(current)
  for i, lvl in ipairs(CYCLE) do
    if lvl == current then
      return CYCLE[i % #CYCLE + 1]
    end
  end
  return "auto"
end

local function render()
  -- Error priority: permission-denied tints red and says "no access".
  if error_ ~= nil and error_.kind == "permission-denied" then
    barWidget.setTooltip({
      { key = "fan", value = "no access" },
      { key = "hint", value = "run setup-fan-permissions.sh" },
    })
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "car-fan", color = "error" }),
      ui.label({ text = noctalia.tr("widget.no-access"), color = "error" }),
    }))
    return
  end

  if status.available ~= true then
    barWidget.setTooltip({ { key = "fan", value = noctalia.tr("widget.unavailable") } })
    barWidget.render(ui.glyph({ name = "car-fan" }))
    return
  end

  local color
  if status.level == "disengaged" then
    color = "error" -- fan forced off — worth alarming about
  elseif status.level ~= "auto" then
    color = "primary" -- fixed level is a manual override
  end

  local children = { ui.glyph({ name = "car-fan", color = color }) }
  if noctalia.getConfig("show_rpm") == true and status.speed ~= nil then
    table.insert(children, ui.label({ text = tostring(status.speed) .. " RPM", color = color }))
  else
    table.insert(children, ui.label({ text = tostring(status.level), color = color }))
  end

  -- Two-column hover readout (key/value rows), like the built-in widgets.
  local rows = {
    { key = "level", value = tostring(status.level) },
  }
  if status.speed ~= nil then
    table.insert(rows, { key = "fan", value = tostring(status.speed) .. " rpm" })
  end
  if status.temp ~= nil then
    table.insert(rows, { key = "cpu", value = `{status.temp} C` })
  end
  barWidget.setTooltip(rows)
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

noctalia.state.watch("fan.status", function(value)
  status = value or { available = false, error = "missing" }
  render()
end)

noctalia.state.watch("fan.error", function(value)
  error_ = value
  render()
end)

function update()
  -- Settings (show_rpm) change without any state event; repaint on ticks.
  render()
end

function onClick()
  noctalia.togglePanel("makefu/ibm-fan:control")
end

function onRightClick()
  -- Allowed while permission-denied: the user gets the error re-notified.
  noctalia.state.set("fan.cmd", { kind = "set", level = nextLevel(status.available == true and status.level or nil) })
end

-- CLI entry: noctalia msg plugin makefu/ibm-fan:bar all toggle
-- Uses the widget's own toggle callback, so the panel anchors under this widget.
function onIpc(event)
  if event == "toggle" or event == "open" then
    noctalia.togglePanel("makefu/ibm-fan:control")
  end
end

render()
