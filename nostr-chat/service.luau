--!nonstrict
-- nostr-chat service - the headless [[service]] entry.
--
-- Owns the daemon bridge: spawns `nostr-chatd listen` via runStream (the
-- only long-lived socket reader; the v5 plugin API has no raw sockets)
-- and forwards one-shot commands via `nostr-chatd cmd` (runAsync).
-- Everything the UI needs lands in noctalia.state, shared with panel.luau:
--
--   chat.meta     {connected, streaming, relaysUp, relaysTotal, relays,
--                  peerName}
--   chat.messages array of daemon Message tables (newest last)
--   chat.unread   live unread count (header + notifications)
--   chat.lastError  most recent daemon error text (panel toast row)
--   chat.cmd      {kind="send"|"send-file"|"mark-read"|"retry"|"cancel",...}
--                 from the panel; {kind="raw", json=...} for verbatim lines
--   chat.open     true while the panel is visible (panel maintains)
--
-- The listen client self-issues the replay on every (re)connect, so the
-- history mirror resyncs on daemon *and* shell restarts without extra
-- plumbing; bridge-up/bridge-down markers only track connection health.

local PLUGIN = "makefu/nostr-chat"
local PANEL = PLUGIN .. ":chat"

local daemonBin = noctalia.getConfig("daemon_bin") or "nostr-chatd"
local maxHistory = tonumber(noctalia.getConfig("max_history")) or 200

---- state -----------------------------------------------------------------

local messages = {} -- newest last; ids deduped via index below
local index = {}    -- id -> position in messages (rebuilt on prune)

local function publishMessages()
  noctalia.state.set("chat.messages", messages)
end

local function rebuildIndex()
  index = {}
  for i, m in ipairs(messages) do
    index[m.id] = i
  end
end

local function setMeta(field, value)
  local meta = noctalia.state.get("chat.meta") or {}
  meta[field] = value
  noctalia.state.set("chat.meta", meta)
end

local function patchMessage(id, patch)
  local i = index[id]
  if not i then
    return
  end
  local m = messages[i]
  local nextm = {}
  for k, v in pairs(m) do
    nextm[k] = v
  end
  for k, v in pairs(patch) do
    nextm[k] = v
  end
  messages[i] = nextm
  publishMessages()
end

local function prune()
  if #messages > maxHistory then
    local excess = #messages - maxHistory
    table.remove(messages, 1)
    for _ = 2, excess do
      table.remove(messages, 1)
    end
    rebuildIndex()
  end
end

---- daemon transport ------------------------------------------------------

local function sendRaw(jsonLine)
  noctalia.runAsync({ daemonBin, "cmd", jsonLine })
end

---- file picker ---------------------------------------------------------
-- The portal dialog outlives the panel: closing the panel destroys its
-- LuauHost and with it any pending runAsync callback, so the picker runs
-- here in the persistent service runtime and reports through chat.attach:
--   {state="busy"} | {state="idle"} | {state="error", message=...}

local PICKER_EXTS = { ".png", ".jpg", ".jpeg", ".svg", ".gif", ".webp" }

-- xdg-desktop-portal FileChooser over busctl: OpenFile answers with the
-- request object path only, the uris arrive on the Response signal.
local PICKER_SH = table.concat({
  [[req=$(busctl --user call org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.FileChooser OpenFile ssa{sv} "" "$1" 0 2>/dev/null | sed -n 's|.*/request/\([^"]*\)".*|/org/freedesktop/portal/desktop/request/\1|p')]],
  '[ -n "$req" ] || exit 2',
  'timeout -s KILL 55s busctl --user --json=short wait "$req" org.freedesktop.portal.Request Response 2>/dev/null',
}, "\n")

-- A killed runtime can leave a stale phase behind; the picker starts idle.
noctalia.state.set("chat.attach", { state = "idle" })
local pickerBusy = false

local function openFilePicker()
  if pickerBusy then
    return
  end
  if not noctalia.commandExists("busctl") then
    noctalia.state.set("chat.attach", { state = "error", message = noctalia.tr("panel.attach-picker-failed") })
    return
  end
  pickerBusy = true
  noctalia.state.set("chat.attach", { state = "busy" })
  local function done(message)
    pickerBusy = false
    noctalia.state.set("chat.attach", message and { state = "error", message = message } or { state = "idle" })
  end
  noctalia.runAsync({ "sh", "-c", PICKER_SH, "nostr-chat", noctalia.tr("panel.attach-image-title") }, function(result)
    if not result then
      done()
      return
    end
    if result.exitCode == 2 then
      done(noctalia.tr("panel.attach-picker-failed"))
      return
    end
    if result.exitCode ~= 0 then
      done() -- timeout kill / dialog dismissed
      return
    end
    noctalia.log("nostr-chat picker: " .. (result.stdout or ""))
    local ok, d = pcall(noctalia.json.decode, result.stdout or "")
    if not ok or type(d) ~= "table" or type(d.data) ~= "table" then
      done()
      return
    end
    local code = d.data[1]
    if type(code) == "table" then code = code.data end -- {type,data} variant wrapper
    if tonumber(code) ~= 0 then
      done() -- user cancelled the dialog
      return
    end
    -- busctl flattens the signal signature into `data`: code first, the
    -- out-params dict last (possibly with extra slots in between).
    local dict
    for i = #d.data, 2, -1 do
      if type(d.data[i]) == "table" then
        dict = d.data[i]
        break
      end
    end
    local uris = dict and dict.uris
    if type(uris) == "table" and uris.data then uris = uris.data end -- ua{sv}/as wrappers
    if type(uris) == "string" then uris = { uris } end
    if type(uris) ~= "table" then
      done()
      return
    end
    local picked
    for _, u in ipairs(uris) do
      if type(u) == "table" and u.data then u = u.data end
      if type(u) == "string" and string.lower(string.sub(u, 1, 7)) == "file://" then
        picked = noctalia.string.urlDecode(string.sub(u, 8))
        break
      end
    end
    if not picked or picked == "" then
      done()
      return
    end
    local ext = string.lower(string.match(picked, "%.[^%.\\/]+$") or "")
    for _, e in ipairs(PICKER_EXTS) do
      if ext == e then
        -- user's own file: never unlink
        sendRaw(noctalia.json.encode({ cmd = "send-file", path = picked, unlink = false }))
        done()
        return
      end
    end
    done(noctalia.tr("panel.attach-error-unsupported") .. ": " .. (ext ~= "" and ext or "no extension"))
  end, 60000)
end

-- The panel posts command intents here; the daemon owns all socket I/O.
local commandHandlers = {
  send = function(c)
    sendRaw(noctalia.json.encode({ cmd = "send", text = c.text or "", replyTo = c.replyTo }))
  end,
  ["send-file"] = function(c)
    -- unlink after upload for mktemp clipboard captures; the panel passes
    -- the flag when it owns the file's lifetime.
    sendRaw(noctalia.json.encode({ cmd = "send-file", path = c.path, unlink = c.unlink }))
  end,
  ["mark-read"] = function()
    sendRaw('{"cmd":"mark-read"}')
  end,
  retry = function(c)
    sendRaw(noctalia.json.encode({ cmd = "retry", id = c.id }))
  end,
  cancel = function(c)
    sendRaw(noctalia.json.encode({ cmd = "cancel", id = c.id }))
  end,
  pick = function()
    openFilePicker()
  end,
  raw = function(c)
    sendRaw(c.json or "")
  end,
}

noctalia.state.watch("chat.cmd", function(cmd)
  if type(cmd) ~= "table" or not cmd.kind then
    return
  end
  local h = commandHandlers[cmd.kind]
  if h then
    h(cmd)
  end
end)

---- panel visibility ------------------------------------------------------
-- The panel owns chat.open (set in its onOpen/onClose); we mirror it to
-- decide between notifying (panel visible: no desktop ping needed) and
-- auto-opening + auto-read on live replies, matching the old shell-side
-- showPanel-on-incoming behavior.

local panelOpen = false
noctalia.state.watch("chat.open", function(v)
  panelOpen = (v == true)
end)

---- event dispatch --------------------------------------------------------

-- Outgoing messages we authored locally (send echo from the daemon's own
-- replay) may arrive while a toast for a failed send is showing; delivery
-- state transitions clear it.
local function dispatch(ev)
  local kind = ev.kind

  if kind == "bridge-up" or kind == "bridge-down" then
    setMeta("connected", kind == "bridge-up")
    if kind == "bridge-down" then
      setMeta("streaming", false)
    end
    return
  end

  if kind == "status" then
    local meta = noctalia.state.get("chat.meta") or {}
    meta.connected = true
    meta.streaming = ev.streaming == true
    meta.relaysUp = ev.relaysUp or 0
    meta.relaysTotal = ev.relaysTotal or 0
    meta.relays = ev.relays or {}
    meta.peerName = ev.name
    noctalia.state.set("chat.meta", meta)
    noctalia.state.set("chat.unread", ev.unread or 0)
    return
  end

  if kind == "msg" and ev.msg then
    local m = ev.msg
    if index[m.id] then
      return -- daemon dedups too; belt over noise
    end
    table.insert(messages, m)
    index[m.id] = #messages
    prune()
    publishMessages()
    -- Live incoming: while the panel is closed, auto-open it (old
    -- Main.qml did showPanel()+markRead() on dir=="in") and ping the
    -- desktop. Replay of unread history shares this path; opening then
    -- fires the panel's mark-read, which is exactly right.
    if m.dir == "in" and not m.read and not panelOpen then
      local meta = noctalia.state.get("chat.meta") or {}
      local snippet = (string.gsub(m.content or "", "%s+", " "))
      if #snippet > 80 then
        snippet = string.sub(snippet, 1, 78) .. ".."
      end
      noctalia.notify(meta.peerName or "Nostr Chat", snippet)
      panelOpen = true -- optimistic; panel onOpen confirms via chat.open
      noctalia.togglePanel(PANEL)
    end
    return
  end

  if kind == "sent" then
    if ev.state == "cancelled" then
      local i = index[ev.target]
      if i then
        table.remove(messages, i)
        rebuildIndex()
        publishMessages()
      end
    else
      patchMessage(ev.target, { state = "sent" })
    end
    return
  end

  if kind == "retry" then
    patchMessage(ev.target, { state = "pending" })
    if (ev.tries or 0) == 1 then
      noctalia.notify("Nostr Chat", "send failed, retrying")
    end
    return
  end

  if kind == "ack" then
    patchMessage(ev.target, { ack = ev.mark or "" })
    return
  end

  if kind == "img" then
    patchMessage(ev.target, { image = ev.image })
    return
  end

  if kind == "error" then
    noctalia.state.set("chat.lastError", ev.text or "daemon error")
    noctalia.notifyError("Nostr Chat", ev.text or "daemon error")
    return
  end
end

---- stream lifecycle ------------------------------------------------------

-- runStream pipes stdout through the dispatcher. The listen client
-- reconnects internally forever; the stream dies only if the child dies
-- (daemon binary gone) or the plugin reloads. Restart lazily via
-- setUpdateInterval: re-arming a live stream is a no-op cheap check.
local streamUp = false

local function startStream()
  local cmd = string.format("%s listen %d", daemonBin, maxHistory)
  streamUp = noctalia.runStream(cmd, function(line)
    if line == nil then
      streamUp = false
      return
    end
    local ev = noctalia.json.decode(line)
    if type(ev) == "table" and ev.kind then
      dispatch(ev)
    end
  end)
  if not streamUp then
    setMeta("connected", false)
  end
end

function update()
  if not streamUp then
    startStream()
  end
  noctalia.setUpdateInterval(10000)
end
noctalia.setUpdateInterval(1000)

---- settings --------------------------------------------------------------

function onConfigChanged()
  local b = noctalia.getConfig("daemon_bin") or "nostr-chatd"
  local h = tonumber(noctalia.getConfig("max_history")) or 200
  if b ~= daemonBin or h ~= maxHistory then
    daemonBin = b
    maxHistory = h
  end
end

---- IPC (hyprland keybind + screenshot script) ----------------------------
-- noctalia msg plugin makefu/nostr-chat:service all toggle|hide [payload]

function onIpc(event, payload)
  if event == "toggle" then
    noctalia.togglePanel(PANEL)
  elseif event == "hide" then
    if panelOpen then
      noctalia.togglePanel(PANEL)
    end
  elseif event == "send" and payload and payload ~= "" then
    sendRaw(noctalia.json.encode({ cmd = "send", text = payload }))
  end
end
