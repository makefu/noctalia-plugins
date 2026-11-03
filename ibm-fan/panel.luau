--!nonstrict
-- ibm-fan control panel — readout + Auto/Full + 0-7 level slider.
--
-- All data comes from the service via the shared state channel; this script
-- never spawns the helper itself. Clicks post {kind="set", level=...} intents
-- to fan.cmd. No title header and no scroll view: the panel is sized so the
-- fixed content always fits, and the error banner replaces the readout rows
-- rather than stacking on top of them.
--
-- Slider UX: onChange keeps a local draft (the 3 s poll would otherwise snap
-- the thumb back mid-drag); onDragEnd commits the draft through fan.cmd. The
-- committed value comes from fan.status, so external changes (bar click, IPC)
-- move the thumb on the next repaint.

local status = noctalia.state.get("fan.status") or { available = false, error = "missing" }
local error_ = noctalia.state.get("fan.error")
local dragDraft = nil

local function sliderValue()
  if dragDraft ~= nil then
    return dragDraft
  end
  if status.available == true then
    local n = tonumber(status.level)
    if n ~= nil then
      return n
    end
  end
  return 0
end

local function levelText()
  if status.available ~= true then
    return "—"
  end
  if dragDraft ~= nil then
    return tostring(dragDraft)
  end
  return tostring(status.level)
end

local function rpmText()
  if status.available ~= true or status.speed == nil then
    return "—"
  end
  return tostring(status.speed)
end

local function tempText()
  if status.available ~= true or status.temp == nil then
    return "—"
  end
  return `{status.temp} C`
end

local function commitLevel(level)
  noctalia.state.set("fan.cmd", { kind = "set", level = level })
end

local function render()
  local children = {}

  -- Banner takes the readout's slot: panel height stays constant either way.
  if error_ ~= nil then
    local lines = { ui.label({ text = tostring(error_.message), color = "error" }) }
    if error_.hint ~= nil and error_.hint ~= "" then
      table.insert(lines, ui.label({ text = tostring(error_.hint), fontSize = 11, color = "on_surface_variant" }))
    end
    table.insert(children, ui.row({ gap = 8, align = "start" }, {
      ui.glyph({ name = "alert-triangle", color = "error" }),
      ui.column({ gap = 2, flexGrow = 1 }, lines),
    }))
  else
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.level"), color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = levelText(), fontWeight = "bold" }),
    }))
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.rpm"), color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = rpmText(), fontWeight = "bold" }),
    }))
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.temp"), color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = tempText(), fontWeight = "bold" }),
    }))
  end

  table.insert(children, ui.row({ gap = 8, align = "stretch" }, {
    ui.button({
      text = noctalia.tr("panel.auto"),
      selected = status.available == true and status.level == "auto",
      onClick = function()
        dragDraft = nil
        commitLevel("auto")
      end,
    }),
    ui.button({
      text = noctalia.tr("panel.full"),
      selected = status.available == true and status.level == "disengaged",
      onClick = function()
        dragDraft = nil
        commitLevel("disengaged")
      end,
    }),
  }))

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = noctalia.tr("panel.level-0-7"), color = "on_surface_variant" }),
    ui.slider({
      min = 0,
      max = 7,
      step = 1,
      value = sliderValue(),
      flexGrow = 1,
      onChange = function(value)
        dragDraft = tonumber(value) or 0
        render()
      end,
      onDragEnd = function(_)
        local level = dragDraft ~= nil and tostring(dragDraft) or nil
        dragDraft = nil
        if level ~= nil then
          commitLevel(level)
        end
      end,
    }),
  }))

  panel.render(ui.column({ gap = 10, align = "fill" }, children))
end

noctalia.state.watch("fan.status", function(value)
  status = value or { available = false, error = "missing" }
  render()
end)

noctalia.state.watch("fan.error", function(value)
  error_ = value
  render()
end)

function onOpen(_context)
  render()
end

render()
