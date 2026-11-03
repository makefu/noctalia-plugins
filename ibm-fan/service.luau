--!nonstrict
-- ibm-fan service — headless owner of all thinkpad-fan.sh I/O and the single
-- funnel for user-visible errors. widget.luau and panel.luau only read state:
--
--   fan.status  { available=true, status, speed, level, temp }
--               | { available=false, error="missing"|"unreadable"|"read-failed" }
--   fan.error   nil | { kind, message, hint?, at }  (sticky last failure;
--               the service clears it on the next success)
--   fan.cmd     { kind="set", level=... }           (posted by widget/panel)

local script = noctalia.pluginDir() .. "/scripts/thinkpad-fan.sh"

-- Same whitelist the script enforces; a bad value never spawns the process.
local VALID_LEVELS = {
  auto = true,
  disengaged = true,
  ["full-speed"] = true,
  ["0"] = true,
  ["1"] = true,
  ["2"] = true,
  ["3"] = true,
  ["4"] = true,
  ["5"] = true,
  ["6"] = true,
  ["7"] = true,
}

local CYCLE = { "auto", "0", "1", "2", "3", "4", "5", "6", "7", "disengaged" }

local lastPollFailed = false
local pollInFlight = false

local function setError(kind, message, hint)
  noctalia.state.set("fan.error", {
    kind = kind,
    message = message,
    hint = hint,
    at = noctalia.nowMs(),
  })
end

---- polling ---------------------------------------------------------------

local function poll()
  if pollInFlight then
    return
  end
  pollInFlight = true
  local zone = noctalia.getConfig("thermal_zone")
  local accepted = noctalia.runAsync({ script, "status", tostring(zone or "thermal_zone0") }, function(result)
    pollInFlight = false
    local data
    if result and result.exitCode == 0 and not result.timedOut then
      local ok, decoded = pcall(noctalia.json.decode, result.stdout or "")
      if ok and type(decoded) == "table" and decoded.available == true then
        data = decoded
      end
    end
    if data ~= nil then
      noctalia.state.set("fan.status", {
        available = true,
        status = data.status,
        speed = data.speed,
        level = data.level,
        temp = data.temp,
      })
      if lastPollFailed then
        -- Recovery: drop the sticky banner the failure transition set.
        lastPollFailed = false
        noctalia.state.set("fan.error", nil)
      end
    else
      noctalia.state.set("fan.status", { available = false, error = "read-failed" })
      if not lastPollFailed then
        -- Failure transition only — no notifyError; a 3 s poll loop would
        -- spam notifications. The widget tint + panel banner carry it.
        lastPollFailed = true
        if result then
          noctalia.log("ibm-fan status exit " .. tostring(result.exitCode) .. " stderr " .. (result.stderr or ""))
        end
        setError("read-failed", noctalia.tr("error.read-failed"), nil)
      end
    end
  end, 10000)
  if not accepted then
    pollInFlight = false
  end
end

local pollInterval = tonumber(noctalia.getConfig("poll_interval")) or 3
noctalia.setUpdateInterval(pollInterval * 1000)

function update()
  poll()
end

---- level writes -----------------------------------------------------------

local function applyLevel(level)
  if type(level) ~= "string" or not VALID_LEVELS[level] then
    setError("invalid-level", noctalia.tr("error.invalid-level"), nil)
    return
  end
  local accepted = noctalia.runAsync({ script, "set", level }, function(result)
    local code = result and result.exitCode or -1
    if code == 0 then
      noctalia.state.set("fan.error", nil)
      poll() -- reflect the new level now; don't wait for the timer
    elseif code == 2 then
      local message = noctalia.tr("error.permission-denied.title")
      local hint = noctalia.tr("error.permission-denied.hint")
      setError("permission-denied", message, hint)
      noctalia.notifyError(noctalia.tr("title"), message .. " " .. hint)
    elseif code == 3 then
      setError("invalid-level", noctalia.tr("error.invalid-level"), nil)
    else
      -- Script-side reject/breakage; raw stderr goes to the log only — it is
      -- not user-safe text for the GUI.
      if result then
        noctalia.log("ibm-fan set " .. level .. " exit " .. tostring(code) .. " stderr " .. (result.stderr or ""))
      end
      setError("script-failed", noctalia.tr("error.script-failed") .. " (exit " .. tostring(code) .. ")", nil)
    end
  end, 10000)
  if not accepted then
    setError("script-failed", noctalia.tr("error.script-failed"), nil)
  end
end

local function nextLevel(current)
  for i, lvl in ipairs(CYCLE) do
    if lvl == current then
      return CYCLE[i % #CYCLE + 1]
    end
  end
  return "auto"
end

-- Widget/panel intents arrive through the shared state channel.
noctalia.state.watch("fan.cmd", function(cmd)
  if type(cmd) == "table" and cmd.kind == "set" then
    applyLevel(cmd.level)
  end
end)

---- IPC ---------------------------------------------------------------------
-- noctalia msg plugin makefu/ibm-fan:service all cycle|set <level>|toggle

function onIpc(event, payload)
  if event == "cycle" then
    local status = noctalia.state.get("fan.status") or {}
    applyLevel(nextLevel(status.available == true and status.level or nil))
  elseif event == "set" then
    applyLevel(payload)
  elseif event == "toggle" then
    noctalia.togglePanel("makefu/ibm-fan:control")
  end
end
