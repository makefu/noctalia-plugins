#!/usr/bin/env python3
"""Locate chat-bubble text geometry in a grim screenshot of the nostr-chat
panel, for the selection E2E (see selection-e2e.sh).

Two seeded incoming bubbles are rendered (single-line A, two-row B). Bubble
columns paint `surface_variant` as a solid fill over the panel background;
the wallpaper gradient, the bar, and the composer fill (surface_variant/0.6
+ border) all fail the fill-run test below, so detection needs no theme
palette knowledge — only that both messages are dir=in.

Row classification (see the profile of a real shot): a bubble's *text* rows
still have the fill as modal colour but only ~40-70% of the scan width,
because antialiased glyph columns count as ink. So runs are grouped with a
LOW modal-fraction floor (RUN_FRAC), while the panel body and every
non-bubble region sit above 0.9 — never confusable with a text row.

The harness supplies the message texts and the plugin's wrap capacity
(MSG_CHARS_PER_ROW). A local greedy-wrap model — same algorithm as
compose_geometry.countRows — predicts each bubble's row count and the word
under a press x. Expected clipboard strings are derived here, so the shell
asserts against one source of truth.

Emits shell-eval assignments:

  DRAG_X0 DRAG_Y DRAG_X1    press near start of bubble A row 0, release
                            near its end (strict-substring assert)
  WORD_X WORD_Y WORD_TEXT   point inside the first word of A
  LINE_X LINE_Y LINE_TEXT   point inside the bottom rendered row of B
  COPY_X COPY_Y             centroid of the copy glyph in A's meta row

Exits non-zero with a reason when the expected structure is missing, so the
harness fails loudly instead of dragging over nothing.
"""

import json
import struct
import sys
import zlib

# Panel geometry (plugin.toml): width 600, floating center. Scan strictly
# inside it, with a margin that skips the rounded corners and border glow.
PANEL_W = 600
SCAN_MARGIN = 4  # px off each panel edge
RUN_FRAC = 0.25  # min modal fraction for a fill row (dense text rows dip to ~0.4)
BAR_BOTTOM = 30  # px: default bar height, excluded from the row scan

MIN_RUN = 26  # px: single-row bubble = 2*padding(10) + text(~17)
MAX_RUN = 260  # px: roomy ceiling for the seeded corpus
BODY_FRAC = 0.85  # a row is "flat" (non-bubble) only at high modal fraction
BG_FRAC = 0.5  # min fraction of the panel-bg colour identifying panel rows
INK_DIFF = 28  # per-channel distance from the region colour counting as ink
INK_FRAC = 0.004  # min ink-covered scan fraction for a text row
SAFE_INSET = 25  # px: keep drag ends inside the row so no stray chars join
CLUSTER_MERGE = 3  # px: gap small enough to merge two ink column clusters
META_SEARCH = 38  # px below a bubble to look for its meta row


def png_read(path):
    """Decode an 8-bit RGB/RGBA PNG (grim output). Mirrors composer_check.py."""
    with open(path, "rb") as fh:
        data = fh.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, idat = 8, bytearray()
    w = h = depth = ctype = None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos : pos + 4])
        tag = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    assert depth == 8, f"depth {depth} unsupported"
    stride = w * ch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p : p + stride])
        p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                line[i] = (
                    line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))
                ) & 255
        out[y * stride : (y + 1) * stride] = line
        prev = line
    return w, h, ch, out


def wrap_rows(text, capacity):
    """Greedy word wrap replicating compose_geometry.countRows: returns a
    list of (logical_line, rows), one entry per \n-split unit, rows being a
    list of word lists laid out into that unit's rendered rows."""
    lines = []
    for logical in text.replace("\r", "\n").split("\n"):
        words = [w for w in logical.split(" ") if w != ""]
        rows, used, row = [], 0, []
        for w in words:
            n = len(w)
            if used == 0:
                used = n
            elif used + 1 + n <= capacity:
                used += 1 + n
            else:
                rows.append(row)
                row, used = [], n
            row.append(w)
            while used > capacity:  # overlong single word splits
                rows.append(row)
                used -= capacity
                row = []
        rows.append(row)
        lines.append((logical, rows))
    return lines


def row_substrings(logical, rows):
    """Char ranges (start, end) of each rendered row within the logical line."""
    spans = []
    pos = 0
    for row in rows:
        joined = " ".join(row)
        start = logical.find(row[0], pos)
        end = start + len(joined)
        spans.append((start, end))
        pos = end
    return spans


def main():
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    shot, capacity, msg_a, msg_b = (
        sys.argv[1],
        int(sys.argv[2]),
        sys.argv[3],
        sys.argv[4],
    )
    w, h, ch, px = png_read(shot)

    def fail(msg):
        print(f"selection_check: {msg}", file=sys.stderr)
        sys.exit(1)

    def shq(s):
        return "'" + s.replace("'", "'\\''") + "'"

    panel_x0 = (w - PANEL_W) // 2 + SCAN_MARGIN
    panel_x1 = (w + PANEL_W) // 2 - SCAN_MARGIN
    if not (0 < panel_x0 < panel_x1 < w):
        fail(f"panel span {panel_x0}..{panel_x1} outside shot {w}x{h}")
    scan_w = panel_x1 - panel_x0

    def color(x, y):
        o = (y * w + x) * ch
        return (px[o], px[o + 1], px[o + 2])

    def modal(y):
        counts = {}
        for x in range(panel_x0, panel_x1):
            c = color(x, y)
            counts[c] = counts.get(c, 0) + 1
        c, n = max(counts.items(), key=lambda kv: kv[1])
        return c, n / scan_w

    if h < BAR_BOTTOM + 200:
        fail(f"shot too short to contain the panel: {h}")

    rows_meta = {}  # y -> (modal colour, fraction); lazy per row

    def rowinfo(y):
        if y not in rows_meta:
            rows_meta[y] = modal(y)
        return rows_meta[y]

    # Panel background = the colour dominating the most of a set of probe
    # rows (a probe row may sit under a bubble or the header, so a single
    # row is not trustworthy).
    tally = {}
    for yy in range(BAR_BOTTOM + 20, h, 40):
        c, f = rowinfo(yy)
        if f > tally.get(c, (0, 0))[1]:
            tally[c] = (yy, f)
    if not tally:
        fail("no probe rows")
    bg = max(tally.items(), key=lambda kv: kv[1][1])[0]
    if tally[bg][1] < BG_FRAC:
        fail(f"no flat panel-body row among probes (best {tally[bg][1]:.2f})")

    # Panel vertical extent: rows dominated by the bg colour.
    panel_rows = [
        y
        for y in range(BAR_BOTTOM, h)
        if rowinfo(y)[0] == bg and rowinfo(y)[1] >= BG_FRAC
    ]
    if not panel_rows:
        fail("no panel-bg rows found")
    panel_top, panel_bottom = panel_rows[0], panel_rows[-1]

    # Fill runs: maximal stretches of rows whose modal colour is one non-bg
    # colour at fraction >= RUN_FRAC (text rows stay modal; they only drop
    # in fraction). Gap of 1 tolerated for stray antialiased border rows.
    runs_by_color = {}
    y = panel_top
    while y <= panel_bottom:
        c, f = rowinfo(y)
        if c != bg and f >= RUN_FRAC:
            y0 = y
            last = y
            y += 1
            while y <= panel_bottom:
                c2, f2 = rowinfo(y)
                if c2 == c and f2 >= RUN_FRAC:
                    last = y
                elif y + 1 <= panel_bottom and rowinfo(y + 1)[:1] == (c,):
                    pass  # 1-row dropout (e.g. a border pixel row)
                else:
                    break
                y += 1
            if MIN_RUN <= last - y0 + 1 <= MAX_RUN:
                runs_by_color.setdefault(c, []).append((y0, last))
        else:
            y += 1

    cands = sorted(runs_by_color.items(), key=lambda kv: -len(kv[1]))
    if not cands or len(cands[0][1]) < 2:
        fail(f"no fill colour with >=2 runs; got {[(c, len(r)) for c, r in cands[:4]]}")
    fill, runs = cands[0]
    runs.sort()
    a, b = runs[0], runs[1]
    if b[0] - a[1] > 200:
        fail(f"bubbles too far apart ({a} {b}); expected adjacent")

    def bands(run, region):
        """Ink row bands within a bubble, measured against `region`."""
        y0, y1 = run
        rows = []
        for yy in range(max(y0 + 3, panel_top), min(y1 - 2, panel_bottom) + 1):
            xs = [
                xx
                for xx in range(panel_x0, panel_x1)
                if any(abs(pp - ff) > INK_DIFF for pp, ff in zip(color(xx, yy), region))
            ]
            if xs and len(xs) / scan_w >= INK_FRAC:
                rows.append((yy, min(xs), max(xs)))
        out = []
        for yy, xl, xr in rows:
            if out and yy - out[-1][1] <= 4:
                out[-1][1] = yy
                out[-1][2] = min(out[-1][2], xl)
                out[-1][3] = max(out[-1][3], xr)
            else:
                out.append([yy, yy, xl, xr])
        return [(o[0], o[1], o[2], o[3]) for o in out]

    ba = bands(a, fill)
    bb = bands(b, fill)

    # Cross-check the pixel band count against the wrap model (the Input must
    # paint every estimated row; a mismatch means wrong capacity estimate or
    # clipped text). Meta rows live OUTSIDE the fill, so runs cover text only.
    la_all = wrap_rows(msg_a, capacity)
    lb_all = wrap_rows(msg_b, capacity)
    exp_a = sum(len(r) for _, r in la_all)
    exp_b = sum(len(r) for _, r in lb_all)
    if len(ba) != exp_a:
        fail(f"bubble A painted {len(ba)} ink bands, wrap model expects {exp_a}")
    if len(bb) != exp_b:
        fail(f"bubble B painted {len(bb)} ink bands, wrap model expects {exp_b}")

    # Press y: band centre, clamped a few px inside the fill run. The Input
    # pans its viewport when a press starts within 12 px of its edge, but the
    # plugin over-counts rows (height = countRows+1), so the buffer never
    # overflows and a pan there is inert.
    def press_y(run, ya, yb):
        c = (ya + yb) // 2
        return min(max(c, run[0] + 8), run[1] - 8)

    ya, yb, xa0, xa1 = ba[0]
    dy = press_y(a, ya, yb)
    wy = press_y(a, ya, yb)

    # Target word = first word of A. Double-click expands from the pressed
    # offset to the surrounding word boundaries, so any x inside the first
    # glyph selects the whole word: a few px past the row's leftmost ink.
    WORD_X = xa0 + min(6, max(1, (xa1 - xa0) // 4))
    WORD_TEXT = msg_a.replace("\n", " ").split(" ")[0]

    # Target row = bottom rendered row of B; LINE_TEXT is that row's exact
    # substring per the wrap model (what triple-click must select).
    text_band = bb[-1]
    logical_b, rows_b = lb_all[-1]
    spans = row_substrings(logical_b, rows_b)
    if len(rows_b) >= 2:
        s, e = spans[-1]
        LINE_TEXT = logical_b[s:e]
    else:
        LINE_TEXT = logical_b
    _, _, lx0, lx1 = text_band
    LINE_X = (lx0 + lx1) // 2
    ly = press_y(b, text_band[0], text_band[1])

    if not (xa0 + SAFE_INSET < xa1 - SAFE_INSET):
        fail(f"bubble A row too short to drag inside: {xa0}..{xa1}")

    # Copy-button target: the meta row sits on the panel bg below the bubble
    # (timestamp + reply/copy/menu glyphs). Ink column clusters, second from
    # right = copy glyph (menu is rightmost).
    my0 = a[1] + 2
    my1 = min(a[1] + META_SEARCH, panel_bottom - 2)
    ink_rows = []
    for yy in range(my0, my1 + 1):
        xs = [
            xx
            for xx in range(panel_x0, panel_x1)
            if any(abs(pp - ff) > INK_DIFF for pp, ff in zip(color(xx, yy), bg))
        ]
        if xs and len(xs) / scan_w >= INK_FRAC:
            ink_rows.append((yy, min(xs), max(xs)))
    if not ink_rows:
        fail(f"no meta-row ink below bubble A between {my0}..{my1}")
    m0, m1 = ink_rows[0][0], ink_rows[-1][0]
    if m1 - m0 > 30:
        fail(f"meta ink spans {m0}..{m1}; too tall to be one glyph row")
    cols = []
    for xx in range(panel_x0, panel_x1):
        cols.append(
            any(
                abs(pp - ff) > INK_DIFF
                for yy in range(m0, m1 + 1)
                for pp, ff in zip(color(xx, yy), bg)
            )
        )
    clusters = []
    start = None
    gap = 0
    for i, on in enumerate(cols):
        if on:
            if start is None:
                start = i
            gap = 0
        elif start is not None:
            gap += 1
            if gap > CLUSTER_MERGE:
                if i - gap - start + 1 >= 2:
                    clusters.append((start + panel_x0, i - gap + panel_x0))
                start = None
    if start is not None and len(cols) - gap - start + 1 >= 2:
        clusters.append((start + panel_x0, len(cols) - gap + panel_x0))
    if len(clusters) < 4:
        fail(
            f"meta row has {len(clusters)} ink clusters, expected >=4 (timestamp+reply+copy+menu): {clusters}"
        )
    c0, c1 = clusters[-2]
    COPY_X = (c0 + c1) // 2
    COPY_Y = (m0 + m1) // 2

    print(f"DRAG_X0={xa0 + SAFE_INSET}")
    print(f"DRAG_Y={dy}")
    print(f"DRAG_X1={xa1 - SAFE_INSET}")
    print(f"WORD_X={WORD_X}")
    print(f"WORD_Y={wy}")
    print(f"LINE_X={LINE_X}")
    print(f"LINE_Y={ly}")
    print(f"WORD_TEXT={shq(WORD_TEXT)}")
    print(f"LINE_TEXT={shq(LINE_TEXT)}")
    print(f"COPY_X={COPY_X}")
    print(f"COPY_Y={COPY_Y}")
    print(
        "# "
        + json.dumps(
            {
                "bg": bg,
                "fill": fill,
                "A": a,
                "B": b,
                "bandsA": ba,
                "bandsB": bb,
                "meta": (m0, m1),
                "clusters": clusters,
            }
        )
    )


main()
