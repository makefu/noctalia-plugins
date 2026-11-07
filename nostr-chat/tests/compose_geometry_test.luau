--!nonstrict
-- Regression tests for the composer sizing module. Run with the luau CLI:
--   luau nostr-chat/tests/compose_geometry_test.luau
-- (require resolves relative to this file). Exits non-zero on the first
-- failure and prints every check that ran before it.
--
-- These guard the two user-visible contracts:
--  1. The composer box grows one line per wrapped text row for every row
--     count up to MAX_ROWS (boxHeight tracks content exactly, so the border
--     always encloses the text and no scrollbar appears early).
--  2. Past MAX_ROWS the box caps and countRows keeps feeding the input's
--     full inner height so the ScrollView's real scrollbar arms.
-- Dialect note: the luau CLI resolves require without the .luau extension,
-- the noctalia host requires it (panel.luau passes "./compose_geometry.luau").
local G = require("../compose_geometry")

local failures = 0
local checks = 0

local function check(name, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

-- countRows ---------------------------------------------------------------
check("empty is one row", G.countRows(""), 1)
check("single line", G.countRows("hello"), 1)
check("explicit newlines", G.countRows("a\nb\nc"), 3)
check("crlf breaks like lf", G.countRows("a\r\nb"), 2)
check("trailing newline adds the caret line", G.countRows("a\n"), 2)

-- The old gmatch("[^\r\n]*") bug double-counted every newline (a zero-width
-- match restarts at the separator). 16 explicit lines must be exactly 16.
local sixteen = {}
for i = 1, 16 do
  sixteen[i] = "line" .. i
end
check("16 explicit lines", G.countRows(table.concat(sixteen, "\n")), 16)

-- Greedy wrap: 3 words of 30 chars -> 30+1+30=61 fits, +1+30=92 wraps.
check("greedy wrap at capacity", G.countRows(("aaa"):rep(1) .. " " .. ("b"):rep(30) .. " " .. ("c"):rep(30) .. " " .. ("d"):rep(30)), 2)
check("exact capacity fits", G.countRows(("x"):rep(G.CHARS_PER_ROW)), 1)
check("capacity plus one wraps", G.countRows(("x"):rep(G.CHARS_PER_ROW + 1)), 2)
check("two capacity words", G.countRows(("x"):rep(G.CHARS_PER_ROW) .. " " .. ("y"):rep(G.CHARS_PER_ROW)), 2)
-- Long unbreakable word: 72 -> 1 row, 145 -> 3 rows (ceil(145/72)).
check("overlong word ceil", G.countRows(("z"):rep(145)), 3)
check("mixed wrap", G.countRows("short line\n" .. ("w"):rep(200) .. "\ntail"), 1 + 3 + 1)

-- charsPerRow override (bubble estimate uses a narrower capacity).
check("override wraps at 20", G.countRows(("x"):rep(21), 20), 2)
check("override exact fits", G.countRows(("x"):rep(20), 20), 1)
check("override beats default", G.countRows(("x"):rep(G.CHARS_PER_ROW), 20), 4)
check("override nil keeps default", G.countRows(("x"):rep(G.CHARS_PER_ROW), nil), 1)

-- contentHeight / wrapped --------------------------------------------------
check("content height empty", G.contentHeight(1), G.LINE_H + G.PAD_V)
check("content height rows", G.contentHeight(4), 4 * G.LINE_H + G.PAD_V)
check("not wrapped at cap", G.wrapped(G.MAX_ROWS), false)
check("wrapped past cap", G.wrapped(G.MAX_ROWS + 1), true)

-- boxHeight: the progressive-growth contract --------------------------------
-- For every row count 1..MAX_ROWS the outer box is exactly the content plus
-- the two border strokes: nothing inside overflows, so the host must not
-- show a scrollbar and the border must sit right under the last line.
for rows = 1, G.MAX_ROWS do
  check(
    ("box hugs content at %d rows"):format(rows),
    G.boxHeight(rows),
    G.contentHeight(rows) + 2 * G.BORDER_W
  )
end
check("box caps past MAX_ROWS", G.boxHeight(G.MAX_ROWS + 5), G.boxHeight(G.MAX_ROWS))
check(
  "capped box has scrollable headroom",
  G.contentHeight(G.MAX_ROWS + 5) > G.boxHeight(G.MAX_ROWS + 5) - 2 * G.BORDER_W,
  true
)
-- Monotonic growth: each extra line adds exactly LINE_H until the cap.
check("row 4 grows by a line", G.boxHeight(2) + G.LINE_H == G.boxHeight(3), true)
check("row cap reached", G.boxHeight(3) + G.LINE_H == G.boxHeight(4), false)

print(("compose_geometry: %d checks, %d failures"):format(checks, failures))
if failures > 0 then
  error("composer geometry regression", 0)
end
