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

---- attach (clipboard image via wl-paste; v5 has no file picker) ----------

local attachSeq = 0

local function attachFromClipboard()
  attachSeq = attachSeq + 1
  local path = string.format("%s/attach-%d-%d.png", noctalia.pluginDataDir(), os.time(), attachSeq)
  noctalia.runAsync({ "wl-paste", "-t", "image/png", path }, function(result)
    if result and result.exitCode == 0 then
      postCmd({ kind = "send-file", path = path, unlink = true })
    end
  end)
end

function onAttachClicked()
  attachFromClipboard()
end

---- tree --------------------------------------------------------------------

local function renderBubble(m)
  local mine = m.dir == "out"
  local hit = searchQuery ~= "" and hits[hitIdx] == m.id

  local content = {}
  if m.image and m.image ~= "" then
    table.insert(content, ui.image({ path = m.image, width = 480, height = 300, fit = "contain" }))
  end
  local text = m.content or ""
  if text ~= "" then
    -- Explicit width is the wrap budget: MarkdownView only caps its labels
    -- when a measure constraint or its own width is known, and a
    -- content-sized parent column advertises neither. 480 = panel 600
    -- minus panel padding, scrollbar, and the bubble's own padding/border.
    table.insert(content, ui.markdown({ text = text, width = 480 }))
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

  local inner = ui.column({ gap = 3 }, { bubble, ui.row({ gap = 4, align = "center" }, metaKids) })
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
