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
-- The panel runtime is destroyed when the panel closes and re-runs this
-- chunk on the next open, so the unsent composer text cannot live in this
-- local alone: it is seeded from draft.txt in the plugin data dir, which
-- is also the only store that survives a shell restart. Missing file ==
-- no draft (sending unlinks it).
local DRAFT_FILE = "draft.txt"

local function draftPath()
  local dir = noctalia.pluginDataDir()
  if not dir or dir == "" then
    return nil
  end
  return dir .. "/" .. DRAFT_FILE
end

local p0 = draftPath()
local composeText = (p0 and noctalia.readFile(p0)) or ""

-- attach state (rendered by the tree below; declared early so the
-- chat.attach watcher can reach these locals, not shadowing globals)
local attachSeq = 0
local attachBusy = false
local attachError = ""
local pickerError = "" -- surfaced by the service-side portal picker
local chooser = nil -- {a=selectionPath, b=primaryPath} while the user picks

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

-- Portal picker phase (service.luau owns the dialog; busy covers the
-- clipboard capture that precedes a pick).
noctalia.state.watch("chat.attach", function(v)
  if type(v) ~= "table" then
    return
  end
  if v.state == "busy" then
    attachBusy = true
    attachError = ""
    pickerError = ""
  else
    attachBusy = false
    pickerError = (v.state == "error" and v.message) or ""
  end
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

-- Composer chrome + sizing lives in ./compose_geometry.luau so the luau CLI
-- can exercise it as a pure regression test
-- (tests/compose_geometry_test.luau). The panel is a ui.scroll box (fill +
-- border + radius) around a frameless multiline Input: the Input's own frame
-- paints radius scaled by its height (stadium arc on a multi-row box) and
-- its label has no inset of the border, which is how the draft used to bleed
-- under the stroke. The ScrollView owns the box instead; its content inset
-- is only the border (paddingV 0 + BORDER_W), so the border hugs the text
-- rows at every draft height. Host require dialect: ./ prefix + .luau ext.
local G = require("./compose_geometry.luau")

-- Caret-follow: the host Input puts its caret at the end of any value it is
-- seeded with and pans only its *internal* offset (inert here, because the
-- input keeps its full estimated height inside the capped ScrollView). The
-- ScrollView itself starts at offset 0 whenever we hand it a fresh node, so
-- without this rev the composer would show the top of a long draft while the
-- caret is at the bottom. Bumped on every draft change -> the viewport lands
-- where the user is typing (paste/send included).
local composeScrollRev = 0

-- Takeover re-pin countdown: focusing the input makes the host scroll it
-- "into view" at its top, which lands the viewport at the *start* of a
-- long draft while the caret sits at the end. update() runs every second
-- tick; for the first couple ticks after opening we bump scrollToBottomRev
-- so the viewport settles at the caret.
local composeFollow = 0

local function setDraft(text)
  if text ~= composeText then
    composeScrollRev = composeScrollRev + 1
  end
  composeText = text
  local p = draftPath()
  if not p then
    return
  end
  if text == "" then
    noctalia.removeFile(p) -- sending unlinks the draft: absence == no draft
  else
    noctalia.writeFile(p, text)
  end
end

local function sendCompose(text)
  text = text or composeText
  setDraft("")
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

-- Drag/double/triple-click on a bubble's markdown lands here with the
-- selected text; the gesture suppresses the bubble reply click, so copying
-- is the only visible effect.
function onMarkdownSelection(text)
  if text and text ~= "" then
    noctalia.copyToClipboard(text)
  end
end

---- attach (recent / clipboard / browse / portal picker / external drop) ---
--
-- wl-paste writes to stdout — there is no positional output file (that is
-- wl-copy's syntax), so every capture redirects through `sh -c`.

-- Globals on purpose: the fixed-name onClick callbacks below are _G
-- functions and must resolve the same storage as render().
attachOpen = false
recentFiles = {}
browsing = false

local IMAGE_MIMES = { "image/png", "image/jpeg", "image/svg+xml" }
local MIME_EXT = { ["image/png"] = ".png", ["image/jpeg"] = ".jpg", ["image/svg+xml"] = ".svg" }

local function attachFail(msg)
  attachBusy = false
  attachError = msg
  render()
end

local function attachPath(ext, tag)
  local dir = noctalia.pluginDataDir()
  if not dir or dir == "" then
    attachFail(noctalia.tr("panel.attach-error-nodata"))
    return nil
  end
  attachSeq = attachSeq + 1
  return string.format("%s/attach-%d-%d-%s%s", dir, os.time(), attachSeq, tag, ext)
end

local function sendAttached(path, unlink)
  chooser = nil
  attachBusy = false
  attachError = ""
  render()
  postCmd({ kind = "send-file", path = path, unlink = unlink })
end

local function discardChooser()
  if chooser then
    if chooser.a then noctalia.removeFile(chooser.a) end
    if chooser.b then noctalia.removeFile(chooser.b) end
    chooser = nil
  end
end

-- One shell lists both clipboards; a dead owner would hang wl-paste, so the
-- 4 s timeout doubles as the "no image" detector.
local PROBE_SH = "wl-paste -l 2>/dev/null; echo '#SEP#'; wl-paste -p -l 2>/dev/null"

local function mimeIn(buf)
  if not buf then return nil, nil end
  local unsupported
  for line in string.gmatch(buf, "[^\r\n]+") do
    local lower = string.lower(line)
    for _, m in ipairs(IMAGE_MIMES) do
      if lower == m then
        return m, unsupported
      end
    end
    if not unsupported and string.find(lower, "^image/") then
      unsupported = line
    end
  end
  return nil, unsupported
end

local function probeClipboards(cb)
  if not noctalia.commandExists("wl-paste") then
    cb(nil, nil, nil)
    return
  end
  noctalia.runAsync({ "sh", "-c", PROBE_SH }, function(result)
    local out = result and result.stdout or ""
    local selBuf, primBuf = string.match(out, "^(.-)#SEP#\n?(.*)$")
    local selMime, selBad = mimeIn(selBuf)
    local primMime, primBad = mimeIn(primBuf)
    cb(selMime, primMime, selBad or primBad)
  end, 4000)
end

-- cb(path) on success; onFail() when the bytes never arrived (a dead owner,
-- empty buffer, or missing data dir).
local function attachCapture(mime, primary, tag, cb, onFail)
  local path = attachPath(MIME_EXT[mime], tag)
  if not path then
    onFail()
    return
  end
  local script = 'wl-paste ${3:+-p} -t "$1" > "$2" 2>/dev/null && test -s "$2"'
  noctalia.runAsync({ "sh", "-c", script, "nostr-chat", mime, path, primary and "-p" or "" }, function(result)
    if result and result.exitCode == 0 then
      cb(path)
    else
      noctalia.removeFile(path)
      onFail()
    end
  end, 5000)
end

-- Both buffers offer images: send one when they are the same bytes, else
-- show the chooser row. A side that fails to capture drops out — the good
-- side still gets sent, only an all-fail set surfaces an error.
local function attachBoth(selMime, primMime)
  local st = { a = nil, b = nil, da = false, db = false, done = false }
  local function settle()
    if st.done or not (st.da and st.db) then
      return
    end
    st.done = true
    if st.a and st.b then
      noctalia.runAsync({ "sh", "-c", 'cmp -s "$1" "$2"', "nostr-chat", st.a, st.b }, function(r)
        if r and r.exitCode == 0 then
          noctalia.removeFile(st.b)
          sendAttached(st.a, true)
        else
          chooser = { a = st.a, b = st.b }
          attachBusy = false
          render()
        end
      end, 5000)
    elseif st.a then
      sendAttached(st.a, true)
    elseif st.b then
      sendAttached(st.b, true)
    else
      attachFail(noctalia.tr("panel.attach-error-paste"))
    end
  end
  attachCapture(selMime, false, "sel",
    function(p) st.a = p st.da = true settle() end,
    function() st.da = true settle() end)
  attachCapture(primMime, true, "prim",
    function(p) st.b = p st.db = true settle() end,
    function() st.db = true settle() end)
end

-- The portal picker itself runs in service.luau: the dialog outlives the
-- panel (a dismiss destroys this runtime and its pending callbacks), and the
-- service reports the outcome through the chat.attach state key.

local function attachGuard()
  if attachBusy or chooser then
    return false
  end
  attachBusy = true
  attachError = ""
  render()
  return true
end

local function sendOne(mime, primary)
  attachCapture(mime, primary, primary and "prim" or "sel",
    function(p) sendAttached(p, true) end,
    function() attachFail(noctalia.tr("panel.attach-error-paste")) end)
end

local function runAttach(textFallback)
  probeClipboards(function(selMime, primMime, unsupported)
    if selMime and primMime then
      if selMime == primMime then
        sendOne(selMime, false)
      else
        attachBoth(selMime, primMime)
      end
    elseif selMime then
      sendOne(selMime, false)
    elseif primMime then
      sendOne(primMime, true)
    elseif unsupported then
      attachFail(noctalia.tr("panel.attach-error-unsupported") .. ": " .. unsupported)
    elseif textFallback then
      local t = noctalia.clipboardText()
      attachBusy = false
      if t and t ~= "" then
        setDraft(composeText .. t)
        composeKey = composeKey + 1
      end
      render()
    else
      pickerError = ""
      attachBusy = false -- the service owns the busy phase from here on
      render()
      postCmd({ kind = "pick" })
    end
  end)
end

-- One list drives every attach-side gate (recent list, browse finder,
-- portal picker result); service.luau keeps its mirror for the service-side
-- picker. Comparisons are always against a lowercased name.
local ATTACH_EXTS = { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg" }

local function isImageName(name)
  local lower = string.lower(name)
  for _, ext in ipairs(ATTACH_EXTS) do
    if string.sub(lower, -#ext) == ext then
      return true
    end
  end
  return false
end

local function sendFile(path, unlink)
  postCmd({ kind = "send-file", path = path, unlink = unlink })
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
-- slot gets its own global. _G is the readonly shared table under the host
-- sandbox, so these must be plain function statements, not _G assignments.
local function sendRecent(i)
  local f = recentFiles[i]
  if f then
    sendFile(f.path, false)
  end
end

function onAttachRecent1() sendRecent(1) end
function onAttachRecent2() sendRecent(2) end
function onAttachRecent3() sendRecent(3) end
function onAttachRecent4() sendRecent(4) end
function onAttachRecent5() sendRecent(5) end
function onAttachRecent6() sendRecent(6) end
function onAttachRecent7() sendRecent(7) end
function onAttachRecent8() sendRecent(8) end

function onClosePanel()
  panel.close()
end

function onAttachClipboard()
  if attachGuard() then runAttach(false) end
end

function onAttachFromKey()
  if attachGuard() then runAttach(true) end
end

function onChooseClipboard()
  if not chooser then return end
  local a = chooser.a
  if chooser.b then noctalia.removeFile(chooser.b) end
  chooser = nil
  sendAttached(a, true)
end

function onChoosePrimary()
  if not chooser then return end
  local b = chooser.b
  if chooser.a then noctalia.removeFile(chooser.a) end
  chooser = nil
  sendAttached(b, true)
end

function onDiscardAttach()
  discardChooser()
  attachBusy = false
  render()
end

-- Drive the flows from `noctalia msg plugin makefu/nostr-chat:chat <event> all`
-- (also usable as a keybind hook).
function onIpc(event, _payload)
  if event == "attach" then
    onAttachClicked()
  elseif event == "paste" then
    onAttachFromKey()
  elseif event == "browse" then
    onAttachBrowse()
  end
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
  local names = {}
  for _, e in ipairs(ATTACH_EXTS) do
    table.insert(names, string.format("-iname '*%s'", e))
  end
  -- newest first: with 400+ candidates an alphabetical head -300 would
  -- drop the images you actually want to send
  local listCmd = string.format(
    "find %s -maxdepth 2 \\( %s \\) -printf '%%T@\\t%%p\\n' 2>/dev/null | sort -rn | cut -f2- | awk '!seen[$0]++' | head -n 300",
    table.concat(findDirs, " "),
    table.concat(names, " -o ")
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

-- Drop sender, parked behind a flag: the host offers a drag to a panel only
-- when the onFilesDropped global exists (and the shell needs an unmerged
-- wl_data_device receiver anyway), so defining it conditionally keeps even
-- patched shells from accepting an offer we would silently swallow. Flip the
-- flag together with the plugin_api bump to 35 once the receiver lands.
local DROP_ENABLED = false

if DROP_ENABLED then
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
    table.insert(content, ui.markdown({ text = text, selectable = true, onSelection = "onMarkdownSelection" }))
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

  -- attach state: chooser previews / inline error / busy hint, above the composer
  if chooser then
    table.insert(body, ui.label({ text = noctalia.tr("panel.attach-choose"), fontSize = 11, color = "muted" }))
    table.insert(body, ui.row({ gap = 8, align = "start" }, {
      ui.column({ gap = 4, align = "center" }, {
        ui.image({ path = chooser.a, width = 250, height = 170, fit = "contain" }),
        ui.button({ text = noctalia.tr("panel.attach-clipboard"), variant = "primary", onClick = "onChooseClipboard" }),
      }),
      ui.column({ gap = 4, align = "center" }, {
        ui.image({ path = chooser.b, width = 250, height = 170, fit = "contain" }),
        ui.button({ text = noctalia.tr("panel.attach-primary"), variant = "primary", onClick = "onChoosePrimary" }),
      }),
      ui.button({ text = noctalia.tr("panel.attach-discard"), variant = "ghost", onClick = "onDiscardAttach" }),
    }))
  end

  if attachBusy then
    table.insert(body, ui.label({ text = noctalia.tr("panel.attach-attaching"), fontSize = 11, color = "muted" }))
  end

  local attachMsg = attachError
  if attachMsg == "" then
    attachMsg = pickerError
  end
  if attachMsg ~= "" then
    table.insert(body, ui.label({ text = attachMsg, color = "error", fontSize = 11, maxWidth = 560 }))
  end

  local online = meta.connected == true and (meta.relaysUp or 0) > 0
  local placeholder = online
      and noctalia.tr("panel.compose-placeholder", { name = peerName() })
      or noctalia.tr("panel.compose-waiting")

  -- Composer: a bordered ui.scroll box that grows with the draft one line
  -- per wrapped row up to MAX_ROWS, then caps and scrolls. The box exists
  -- from the first row (the Input itself stays frameless: its frame paints
  -- radius scaled by its height, a stadium arc on tall boxes, and its label
  -- ignores the border), so the stroke always encloses the text. The row
  -- carries the explicit height + align="stretch": Flex clamps its own
  -- height before arranging stretch children, and a scroll view sizes from
  -- the exact height it is arranged with (its min/maxHeight props are
  -- otherwise ignored by ScrollView::doLayout). Buttons ride in centering
  -- columns so the stretch does not inflate them.
  local rows = G.countRows(composeText)
  local composer = ui.input({
    key = "compose-" .. composeKey,
    -- Uncontrolled host input: `value` seeds only when the node is created,
    -- so every programmatic edit (send, Ctrl+V paste) bumps composeKey and
    -- the fresh node re-seeds from composeText.
    value = composeText,
    multiline = true,
    submitOnEnter = true,
    flexGrow = 1,
    -- Full estimated height inside the viewport: past the cap this is what
    -- arms the ScrollView's real scrollbar; below it the box hugs it.
    height = G.contentHeight(rows),
    focus = true,
    frameVisible = false,
    onChange = "onComposeChange",
    onSubmit = "onComposeSubmit",
  })
  composer = ui.scroll({
    key = "compose-scroll-" .. composeKey,
    flexGrow = 1,
    align = "stretch", -- scroll content is a vertical flex: stretch gives the input the viewport width
    fill = "surface_variant/0.6",
    border = "outline/0.6",
    radius = 10,
    borderWidth = G.BORDER_W,
    paddingH = 10,
    -- No vertical padding: the Input already pads its label by 8 px top and
    -- bottom (kMultilinePadV); anything here would push the content past
    -- boxHeight and fake a scrollbar at short drafts.
    paddingV = 0,
    scrollToBottomRev = composeScrollRev,
  }, { composer })

  local paperclip = ui.button({
    glyph = "paperclip",
    variant = "ghost",
    glyphSize = 16,
    enabled = not attachBusy,
    tooltip = noctalia.tr("panel.attach-image-tooltip"),
    onClick = "onAttachClicked",
  })
  local sendButton = ui.button({ glyph = "send", variant = "primary", enabled = composeText ~= "", onClick = "onSendClicked" })
  paperclip = ui.column({ justify = "center", align = "center" }, { paperclip })
  sendButton = ui.column({ justify = "center", align = "center" }, { sendButton })

  table.insert(body, ui.row({ gap = 8, align = "stretch", height = G.boxHeight(rows) }, {
    paperclip,
    composer,
    sendButton,
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, body))
end

function onComposeChange(value)
  setDraft(value or "")
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
  elseif (pressed == true or pressed == "true") and spec == "ctrl+v" then
    onAttachFromKey()
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
  composeScrollRev = composeScrollRev + 1 -- fresh scroll node: land at the caret (bottom)
  hitIdx = 0
  revealKey = ""
  replyTarget = nil
  -- composeText deliberately survives close/reopen (persisted draft);
  -- it clears on send or when the user deletes the text themselves.
  composeFollow = 2
  attachOpen = false
  recentFiles = {}
  composeKey = composeKey + 1 -- fresh compose input grabs focus on open
  pickerError = ""
  attachBusy = false
  attachError = ""
  discardChooser() -- abandoned temp captures must not linger
  postCmd({ kind = "mark-read" })
  render()
end

function onClose()
  noctalia.state.set("chat.open", false)
end

-- Second ticks keep the "ago" timestamps honest while the panel is open.
function update()
  if composeFollow > 0 then
    composeFollow = composeFollow - 1
    composeScrollRev = composeScrollRev + 1 -- undo the focus scroll-into-view top-pin
  end
  render()
end

render()
