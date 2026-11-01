--!nonstrict
-- nostr-chat panel - the [[panel]] entry: live NIP-17 DM chat.
--
-- Thin UI client of service.luau via noctalia.state: renders chat.messages
-- / chat.meta / chat.lastError, posts intents back through chat.cmd.
-- The daemon (not the shell) owns history; the service mirrors it.
--
-- Scroll contract (task #2): stickToBottom keeps the newest messages on
-- screen while content grows, and on every open we bump scrollToBottomRev
-- so the panel always lands at the bottom regardless of where it was
-- closed. onScroll tracks whether the user is at the bottom; leaving it
-- un-pins the follow and arms the "n new" pill.

local msgs = {}
local meta = {}
local lastError = ""

-- Defined below but referenced by callbacks declared above; global so the
-- host and every closure resolve the single function value.
function render() end

-- view state (panel-local, not shared)
local atBottom = true
local unseen = 0
local scrollRev = 0
local revealKey = ""
local searchOpen = false
local searchQuery = ""
local searchKey = 0
local hits = {}   -- message ids matching searchQuery, oldest first
local hitIdx = 0  -- 1-based index into hits (0 = none)
local replyTarget = nil   -- {id, text} of the message being replied to
local composeKey = 0
local composeText = ""

-- Seed before watching: the service pushed its initial state long before
-- this runtime exists (panels are created on first open); watch alone would
-- leave the panel blind until the next daemon event.
msgs = noctalia.state.get("chat.messages") or {}
meta = noctalia.state.get("chat.meta") or {}
lastError = noctalia.state.get("chat.lastError") or ""

noctalia.state.watch("chat.messages", function(v)
  local grew = #msgs < #v
  msgs = v or {}
  if grew and not atBottom then
    unseen = unseen + 1
  end
  render()
end)
noctalia.state.watch("chat.meta", function(v)
  meta = v or {}
  render()
end)
noctalia.state.watch("chat.lastError", function(v)
  lastError = v or ""
  render()
end)

local function peerName()
  return meta.peerName or noctalia.tr("panel.default-peer-name")
end

local function ago(ts)
  local d = os.time() - (ts or 0)
  if d < 45 then
    return noctalia.tr("panel.time-now")
  elseif d < 3600 then
    return tostring(d // 60) .. "m"
  elseif d < 86400 then
    return tostring(d // 3600) .. "h"
  end
  return os.date("%Y-%m-%d", ts)
end

---- actions ---------------------------------------------------------------

local function postCmd(cmd)
  noctalia.state.set("chat.cmd", cmd)
end

local function sendCompose(text)
  text = text or composeText
  composeText = ""
  if text == nil or text == "" then
    return
  end
  postCmd({ kind = "send", text = text, replyTo = replyTarget and replyTarget.id or nil })
  composeKey = composeKey + 1 -- fresh input: clears the field and refocuses
  render()
end

local function setReplyTarget(m)
  replyTarget = { id = m.id, text = m.content or "" }
  composeKey = composeKey + 1
  render()
end

-- Search ------------------------------------------------------------------

local function runSearch(q)
  searchQuery = q or ""
  hits = {}
  hitIdx = 0
  if searchQuery ~= "" then
    local needle = string.lower(searchQuery)
    for _, m in ipairs(msgs) do
      if string.find(string.lower(m.content or ""), needle, 1, true) then
        table.insert(hits, m.id)
      end
    end
    hitIdx = #hits
  end
  stepHit()
end

function stepHit()
  if hitIdx >= 1 and hitIdx <= #hits then
    revealKey = "msg-" .. hits[hitIdx]
  end
  render()
end

function onSearchChange(value)
  runSearch(value)
end

function onSearchSubmit()
  if #hits == 0 then
    return
  end
  hitIdx = hitIdx % #hits + 1 -- Enter walks toward newer, wraps
  stepHit()
end

function onSearchClose()
  searchOpen = false
  searchQuery = ""
  hits = {}
  hitIdx = 0
  render()
end

---- scroll follow ----------------------------------------------------------

function onScroll(offset, maxOffset)
  local off = tonumber(offset) or 0
  local max = tonumber(maxOffset) or 0
  local wasBottom = atBottom
  atBottom = max - off <= 2
  if atBottom ~= wasBottom then
    if atBottom then
      unseen = 0
    end
    render()
  end
end

local function jumpBottom()
  scrollRev = scrollRev + 1
  unseen = 0
  atBottom = true
  render()
end

---- context menu (per-bubble) ----------------------------------------------

local menuMsg = nil

local function openBubbleMenu(m)
  return function()
    menuMsg = m
    local items = {
      { id = "reply", label = noctalia.tr("bubble.reply-tooltip") },
      { id = "copy", label = "Copy text" },
    }
    if m.dir == "out" and m.state == "pending" then
      table.insert(items, { kind = "separator" })
      table.insert(items, { id = "retry", label = "Retry now" })
      table.insert(items, { id = "cancel", label = "Cancel send" })
    end
    panel.openContextMenu({ items = items, onActivate = "onBubbleAction", context = m.id })
  end
end

function onBubbleAction(action, id)
  local m = menuMsg
  if not m or m.id ~= id then
    -- menu outlived its message (pruned/cancelled); fall back to lookup
    for _, c in ipairs(msgs) do
      if c.id == id then
        m = c
        break
      end
    end
    if not m then
      return
    end
  end
  if action == "reply" then
    setReplyTarget(m)
  elseif action == "copy" then
    noctalia.copyToClipboard(m.content or "")
  elseif action == "retry" then
    postCmd({ kind = "retry", id = id })
  elseif action == "cancel" then
    postCmd({ kind = "cancel", id = id })
  end
end

---- attach (recent / clipboard / browse / external drop) -------------------

-- Globals on purpose: the fixed-name onClick callbacks below are _G
-- functions and must resolve the same storage as render().
attachSeq = 0
attachOpen = false
recentFiles = {}
browsing = false

local function isImageName(name)
  local lower = string.lower(name)
  for _, ext in ipairs({ ".png", ".jpg", ".jpeg", ".gif", ".webp" }) do
    if string.sub(lower, -#ext) == ext then
      return true
    end
  end
  return false
end

local function attachCapturePath()
  attachSeq = attachSeq + 1
  return string.format("%s/attach-%d-%d.png", noctalia.pluginDataDir(), os.time(), attachSeq)
end

local function sendFile(path, unlink)
  postCmd({ kind = "send-file", path = path, unlink = unlink })
end

-- wl-paste has no positional output argument: `wl-paste -t image/png out.png`
-- writes nothing and exits 1. Redirect in a shell instead.
local function attachFromClipboard()
  local path = attachCapturePath()
  noctalia.runAsync({ "sh", "-c", string.format("wl-paste -t image/png > '%s'", path) }, function(result)
    local info = result and result.exitCode == 0 and noctalia.fileInfo(path) or nil
    if info and not info.isDir and (info.size or 0) > 0 then
      sendFile(path, true)
      return
    end
    noctalia.removeFile(path)
    noctalia.notifyError("Nostr Chat", noctalia.tr("panel.attach-no-clipboard-image"))
  end)
end

local function listRecentImages(limit)
  local files = {}
  for _, dir in ipairs({ "~/Downloads", "~/Pictures" }) do
    local expanded = noctalia.expandPath(dir)
    local entries = expanded and noctalia.listDir(expanded) or nil
    if entries then
      for _, name in ipairs(entries) do
        if isImageName(name) then
          local full = expanded .. "/" .. name
          local info = noctalia.fileInfo(full)
          if info and not info.isDir then
            table.insert(files, { path = full, name = name, mtime = info.mtime or 0 })
          end
        end
      end
    end
  end
  table.sort(files, function(a, b) return a.mtime > b.mtime end)
  local out = {}
  for i = 1, math.min(limit, #files) do
    table.insert(out, files[i])
  end
  return out
end

function onAttachClicked()
  attachOpen = not attachOpen
  if attachOpen then
    recentFiles = listRecentImages(8)
  end
  render()
end

function onCloseAttach()
  attachOpen = false
  render()
end

-- Fixed-name callbacks: ui.button onClick carries no payload, so each recent
-- slot gets its own global. Luau allows _G assignment from a loop.
for i = 1, 8 do
  _G["onAttachRecent" .. i] = function()
    local f = recentFiles[i]
    if f then
      sendFile(f.path, false)
    end
  end
end

function onClosePanel()
  panel.close()
end

function onAttachClipboard()
  attachFromClipboard()
end

-- Native picker: `noctalia dmenu` pipes candidate lines to the launcher panel
-- and prints the selection to stdout (exit 1 = cancelled). runAsync default
-- timeout is 5s — a human picking a file needs longer (max is 60s).
function onAttachBrowse()
  if browsing then
    return
  end
  browsing = true
  render()
  local dirs = { noctalia.expandPath("~/Downloads"), noctalia.expandPath("~/Pictures"), noctalia.expandPath("~") }
  local findDirs = {}
  for _, d in ipairs(dirs) do
    table.insert(findDirs, string.format("'%s'", d))
  end
  local listCmd = string.format(
    "find %s -maxdepth 2 \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \\) 2>/dev/null | sort | head -n 300",
    table.concat(findDirs, " ")
  )
  noctalia.runAsync(listCmd, function(list)
    local lines = list and list.exitCode == 0 and list.stdout or ""
    if lines == "" then
      browsing = false
      render()
      noctalia.notifyError("Nostr Chat", noctalia.tr("panel.attach-no-files"))
      return
    end
    local body = 'printf "%s\\n" "$0" | noctalia dmenu -p "Attach file"'
    noctalia.runAsync({ "sh", "-c", body, lines }, function(pick)
      browsing = false
      render()
      local selection = pick and pick.exitCode == 0 and pick.stdout or ""
      selection = string.gsub(selection, "%s+$", "")
      if selection ~= "" and noctalia.fileInfo(selection) then
        attachOpen = false
        sendFile(selection, false)
        return
      end
      if pick and pick.exitCode ~= 0 and pick.exitCode ~= 1 then
        noctalia.notifyError("Nostr Chat", noctalia.tr("panel.attach-picker-failed"))
      end
    end, 60000)
  end, 15000)
end

-- Called by the host when files are dropped on the panel surface
-- (noctalia-shell wl_data_device patch). One newline-separated argument.
function onFilesDropped(joined)
  if type(joined) ~= "string" or joined == "" then
    return
  end
  local sent, rejected = 0, 0
  for line in string.gmatch(joined, "[^\\r\\n]+") do
    local path = string.gsub(line, "^file://", "")
    path = string.gsub(string.gsub(path, "%%20", " "), "%s+$", "")
    local info = noctalia.fileInfo(path)
    if info and not info.isDir and isImageName(path) then
      sendFile(path, false)
      sent = sent + 1
    else
      rejected = rejected + 1
    end
  end
  if sent == 0 and rejected > 0 then
    noctalia.notifyError("Nostr Chat", noctalia.tr("panel.attach-drop-unsupported"))
  end
end

---- tree --------------------------------------------------------------------

local function renderBubble(m)
  local mine = m.dir == "out"
  local hit = searchQuery ~= "" and hits[hitIdx] == m.id

  local content = {}
  if m.image and m.image ~= "" then
    table.insert(content, ui.image({ path = m.image, width = 438, height = 300, fit = "contain" }))
  end
  local text = m.content or ""
  if text ~= "" then
    -- No width prop here on purpose: markdown's width is applied as
    -- min=max node clamp, which both forces 480-wide boxes and still
    -- leaves the labels without a wrap budget. The wrap width arrives
    -- through the layout instead: `inner` carries an explicit width, so
    -- the stretch chain hands MarkdownView a real max-width constraint.
    table.insert(content, ui.markdown({ text = text }))
  end

  -- ui.box is decoration-only in the v5 host (children are dropped), so the
  -- bubble itself is a styled column; the flex carries fill/radius/border.
  local bubble = ui.column({
    key = "bub-" .. m.id,
    gap = 6,
    fill = mine and "primary/0.15" or "surface_variant",
    radius = 12,
    padding = 10,
    border = (hit or mine) and "primary" or nil,
    borderWidth = hit and 2 or (mine and 1 or 0),
    align = "start",
    onClick = function()
      setReplyTarget(m)
    end,
  }, content)

  -- quote of the replied-to message, above the bubble
  local parts = {}
  if m.replyTo and m.replyTo ~= "" then
    local quoted, missing = nil, true
    for _, c in ipairs(msgs) do
      if c.id == m.replyTo then
        quoted = c
        missing = false
        break
      end
    end
    local snippet = missing and noctalia.tr("bubble.quote-missing")
        or string.gsub((quoted.content or ""), "%s+", " ")
    if #snippet > 80 then
      snippet = string.sub(snippet, 1, 78) .. ".."
    end
    table.insert(parts, ui.row({
      key = "quote-" .. m.id,
      gap = 6,
      align = "center",
      fill = "surface_variant/0.5",
      radius = 8,
      padding = 6,
      onClick = function()
        revealKey = "msg-" .. m.replyTo
        render()
      end,
    }, {
      ui.glyph({ name = "corner-down-right", size = 12 }),
      ui.label({ text = snippet, maxLines = 1, maxWidth = 420, fontSize = 11 }),
    }))
  end

  -- meta row: timestamp + delivery indicators (right-aligned for mine is
  -- handled by the outer row's justify)
  local metaKids = { ui.label({ text = ago(m.ts), fontSize = 10, color = "on_surface_variant/0.7" }) }
  if mine then
    if m.state == "pending" then
      table.insert(metaKids, ui.glyph({ name = "hourglass", size = 11, color = "on_surface_variant/0.7" }))
    end
    if m.ack and m.ack ~= "" then
      table.insert(metaKids, ui.glyph({ name = "check", size = 11, color = "primary/0.8" }))
    end
  end
  -- openContextMenu only works from a button onRightClick (the sole callback
  -- the host gives a pointer context), so each bubble carries a menu button.
  table.insert(metaKids, ui.button({
    key = "menu-" .. m.id,
    glyph = "dots-vertical",
    variant = "ghost",
    glyphSize = 12,
    controlSize = "sm",
    onRightClick = openBubbleMenu(m),
  }))

  -- flexGrow + stretch is the wrap-budget chain: the msg row gets an exact
  -- width from the scroll viewport, then a flexGrow child is re-measured
  -- with that exact main-axis share (flex.cpp flexGrow pass). Stretching
  -- the bubble to it hands MarkdownView a real max-width constraint so its
  -- labels wrap instead of measuring single-line and overflowing the panel.
  -- (A `width` prop would only clamp min=max, never propagating a budget.)
  local inner = ui.column({
    key = "inner-" .. m.id,
    gap = 3,
    flexGrow = 1,
    align = "stretch",
  }, { bubble, ui.row({ gap = 4, align = "center", justify = mine and "end" or "start" }, metaKids) })
  table.insert(parts, inner)

  return ui.row({
    key = "msg-" .. m.id,
    gap = 6,
    align = "start",
    justify = mine and "end" or "start",
  }, parts)
end

function render()
  local statusText, statusColor
  if not meta.connected then
    statusText = noctalia.tr("panel.status-offline")
    statusColor = "error"
  elseif (meta.relaysUp or 0) <= 0 then
    statusText = noctalia.tr("panel.status-offline")
    statusColor = "error"
  else
    statusText = noctalia.tr("panel.status-connected")
    statusColor = "primary"
  end
  local relayTip = table.concat(meta.relays or {}, "\n")

  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "message-chatbot", size = 18, color = "primary" }),
    ui.label({ text = peerName(), fontWeight = "bold", flexGrow = 1 }),
    ui.box({ width = 8, height = 8, radius = 4, fill = statusColor, tooltip = relayTip }),
    ui.label({ text = statusText, fontSize = 11, color = statusColor }),
    ui.button({ glyph = "search", variant = "ghost", glyphSize = 14, onClick = "onSearchButton" }),
    ui.button({ glyph = "x", variant = "ghost", glyphSize = 14, tooltip = noctalia.tr("panel.close-tooltip"), onClick = "onClosePanel" }),
  })

  function onSearchButton()
    searchOpen = true
    searchKey = searchKey + 1 -- fresh input grabs focus
    render()
  end

  local rows = {}
  for _, m in ipairs(msgs) do
    table.insert(rows, renderBubble(m))
  end

  local body = { header }

  -- In-panel attach picker. A popup/context menu would need pointer-context
  -- serials the button click doesn't carry, and an external dmenu would steal
  -- focus; rendering it inline keeps every click inside the panel.
  if attachOpen then
    table.insert(body, ui.column({ gap = 4, align = "stretch", fill = "surface_variant/0.5", radius = 10, padding = 8 }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = noctalia.tr("panel.attach-title"), fontWeight = "bold", fontSize = 12, flexGrow = 1 }),
        ui.button({ glyph = "x", variant = "ghost", glyphSize = 12, onClick = "onCloseAttach" }),
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = noctalia.tr("panel.attach-clipboard"), variant = "secondary", glyph = "clipboard", onClick = "onAttachClipboard" }),
        ui.button({ text = noctalia.tr("panel.attach-browse"), variant = "secondary", glyph = "folder", onClick = "onAttachBrowse" }),
      }),
      #recentFiles > 0 and ui.label({ text = noctalia.tr("panel.attach-recent"), fontSize = 10, color = "on_surface_variant/0.8" }) or nil,
      #recentFiles > 0 and ui.scroll({ height = 118, gap = 3, align = "stretch" }, (function()
        local items = {}
        for i, f in ipairs(recentFiles) do
          table.insert(items, ui.button({
            key = "recent-" .. i .. "-" .. f.path,
            text = f.name,
            variant = "ghost",
            glyph = "image",
            onClick = "onAttachRecent" .. i,
          }))
        end
        return items
      end)()) or nil,
      ui.label({ text = noctalia.tr("panel.attach-drop-hint"), fontSize = 10, color = "on_surface_variant/0.6" }),
    }))
  end

  if searchOpen then
    local counter = #hits > 0 and string.format("%d/%d", hitIdx, #hits) or ""
    table.insert(body, ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "search-" .. searchKey,
        value = searchQuery,
        placeholder = noctalia.tr("panel.search-placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        focus = true,
        onChange = "onSearchChange",
        onSubmit = "onSearchSubmit",
      }),
      ui.label({ text = counter, fontSize = 11, color = "on_surface_variant" }),
      ui.button({ glyph = "chevron-up", variant = "ghost", glyphSize = 14, onClick = "onSearchPrev" }),
      ui.button({ glyph = "chevron-down", variant = "ghost", glyphSize = 14, onClick = "onSearchNext" }),
      ui.button({ glyph = "x", variant = "ghost", glyphSize = 14, onClick = "onSearchClose" }),
    }))
  end

  function onSearchPrev()
    if #hits > 0 then
      hitIdx = (hitIdx - 2) % #hits + 1
      stepHit()
    end
  end

  function onSearchNext()
    if #hits > 0 then
      hitIdx = hitIdx % #hits + 1
      stepHit()
    end
  end

  table.insert(body, ui.scroll({
    flexGrow = 1,
    gap = 8,
    align = "stretch",
    stickToBottom = atBottom,
    scrollToBottomRev = scrollRev,
    onScroll = "onScroll",
    revealKey = revealKey,
  }, rows))

  if unseen > 0 and not atBottom then
    table.insert(body, ui.row({ justify = "center" }, {
      ui.button({ text = noctalia.trp("panel.new-messages", unseen), variant = "primary", onClick = "onJumpBottom" }),
    }))
  end

  function onJumpBottom()
    jumpBottom()
  end

  if lastError ~= "" then
    table.insert(body, ui.label({ text = lastError, color = "error", fontSize = 11, maxWidth = 560 }))
  end

  if replyTarget then
    local snippet = string.gsub(replyTarget.text, "%s+", " ")
    if #snippet > 80 then
      snippet = string.sub(snippet, 1, 78) .. ".."
    end
    table.insert(body, ui.row({ gap = 6, align = "center", fill = "surface_variant/0.6", radius = 8, padding = 6 }, {
      ui.glyph({ name = "corner-down-right", size = 13, color = "primary" }),
      ui.label({ text = snippet, flexGrow = 1, maxLines = 1, maxWidth = 460, fontSize = 11 }),
      ui.button({ glyph = "x", variant = "ghost", glyphSize = 12, onClick = "onClearReply" }),
    }))
  end

  function onClearReply()
    replyTarget = nil
    render()
  end

  local online = meta.connected == true and (meta.relaysUp or 0) > 0
  local placeholder = online
      and noctalia.tr("panel.compose-placeholder", { name = peerName() })
      or noctalia.tr("panel.compose-waiting")

  table.insert(body, ui.row({ gap = 8, align = "end" }, {
    ui.button({
      glyph = "paperclip",
      variant = "ghost",
      glyphSize = 16,
      tooltip = noctalia.tr("panel.attach-image-tooltip"),
      onClick = "onAttachClicked",
    }),
    ui.input({
      key = "compose-" .. composeKey,
      value = "",
      placeholder = placeholder,
      multiline = true,
      submitOnEnter = true,
      flexGrow = 1,
      height = 38,
      focus = true,
      onChange = "onComposeChange",
      onSubmit = "onComposeSubmit",
    }),
    ui.button({ glyph = "send", variant = "primary", enabled = composeText ~= "", onClick = "onSendClicked" }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, body))
end

function onComposeChange(value)
  composeText = value or ""
  render()
end

function onComposeSubmit(value)
  sendCompose(value)
end

function onSendClicked()
  sendCompose()
end

---- capture_keys (declared in plugin.toml) ----------------------------------

function onKey(spec, pressed)
  if (pressed == true or pressed == "true") and spec == "ctrl+f" then
    searchOpen = true
    searchKey = searchKey + 1
    render()
  end
end

---- lifecycle ---------------------------------------------------------------

function onOpen(_context)
  noctalia.state.set("chat.open", true)
  panel.setWantsSecondTicks(true)
  atBottom = true
  unseen = 0
  scrollRev = scrollRev + 1 -- land at the bottom whatever the last offset was
  searchOpen = false
  searchQuery = ""
  hits = {}
  hitIdx = 0
  revealKey = ""
  replyTarget = nil
  composeText = ""
  attachOpen = false
  recentFiles = {}
  composeKey = composeKey + 1 -- fresh compose input grabs focus on open
  postCmd({ kind = "mark-read" })
  render()
end

function onClose()
  noctalia.state.set("chat.open", false)
end

-- Second ticks keep the "ago" timestamps honest while the panel is open.
function update()
  render()
end

render()
