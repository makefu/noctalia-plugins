--!nonstrict
-- Pure composer sizing for panel.luau, split out so it is requireable from
-- both the noctalia plugin host (require "./compose_geometry.luau") and the
-- luau CLI test runner (tests/compose_geometry_test.luau).
--
-- Pixel-calibrated against the flake-pinned host (v5.4.1 cece614) on a real
-- compositor: a 14 px font paints a 17 px line pitch in the multiline Input
-- (label rows at +8 leading, ink bands 422/439/456/...), and the Input's
-- kMultilinePadV = Style::spaceSm = 8 pins the label 8 px under the top and
-- leaves 8 px at the bottom, so the input's real content height is
-- rows * 17 + 16.
--
-- The composer chrome is a ui.scroll box around the input: the Input paints
-- no frame (frameVisible = false, its height-scaled stadium arc looks wrong
-- on a multi-row box), the ScrollView owns the fill + border. Its doLayout
-- insets the content by (paddingV + borderWidth) on both sides, so the box
-- height must add BORDER_W back twice or the content overflows the viewport
-- and the host shows a scrollbar early.
--
-- The row estimate must track the host exactly. Over-count leaves blank
-- space *below* the text and stickToBottom pins the viewport into the blank;
-- under-count is self-healing: the host Input pans its own text so the caret
-- stays visible (ensureCursorVisibleY) and only yields the wheel to the
-- ancestor ScrollView once its internal offset is clamped. Capacity measured
-- with a 100-word single-line draft: 67..78 glyphs fit a row between the
-- buttons at panel width; 72 biases to under-count.
local M = {}

M.LINE_H = 17
M.PAD_V = 16 -- 2 * kMultilinePadV (Style::spaceSm = 8)
M.BORDER_W = 1 -- the borderWidth the panel passes to the composer scroll box
M.CHARS_PER_ROW = 72
M.MAX_ROWS = 3

-- Wrapped-line count of the draft under greedy word wrapping at
-- CHARS_PER_ROW. Mirrors the host's newline handling: \r and \n both break.
-- "" is one row (the empty caret line).
function M.countRows(text)
  if text == "" then
    return 1
  end
  local rows = 0
  for line in string.gmatch(text .. "\n", "([^\r\n]*)\n") do
    local count, used = 1, 0
    for word in string.gmatch(line, "%S+") do
      local w = #word
      if used == 0 then
        used = w
      elseif used + 1 + w <= M.CHARS_PER_ROW then
        used = used + 1 + w
      else
        count = count + 1
        used = w
      end
      while used > M.CHARS_PER_ROW do -- overlong single word
        count = count + 1
        used = used - M.CHARS_PER_ROW
      end
    end
    rows = rows + count
  end
  return rows
end

-- Height to hand the Input node: it keeps its full estimated height inside
-- the scroll viewport, which is what arms the ScrollView's real scrollbar
-- once the draft outgrows MAX_ROWS.
function M.contentHeight(rows)
  return rows * M.LINE_H + M.PAD_V
end

function M.wrapped(rows)
  return rows > M.MAX_ROWS
end

-- Outer height of the composer scroll box. Up to MAX_ROWS the box hugs the
-- content line-for-line (progressive growth, no internal scroll); beyond
-- that it caps and the input scrolls inside it. + 2 * BORDER_W compensates
-- the viewport inset ScrollView::doLayout applies (clipInset = border,
-- paddingV is 0 here), so no scrollbar appears while nothing overflows.
function M.boxHeight(rows)
  local visible = rows
  if visible > M.MAX_ROWS then
    visible = M.MAX_ROWS
  end
  return visible * M.LINE_H + M.PAD_V + 2 * M.BORDER_W
end

return M
