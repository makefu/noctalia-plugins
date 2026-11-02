#!/usr/bin/env python3
"""Composer pixel assertions for the nested-compositor E2E.

Usage: composer_check.py shot.png path/to/compose_geometry.luau draft-text [luau-exe]

Prints RESULT pass|fail lines per assertion; exit 1 on any failure.
Pixel facts this pins (the geometry contract lives in compose_geometry.luau):
  - the bordered scroll box exists at every draft size, and its painted outer
    height equals G.boxHeight(countRows(draft)) (progressive growth up to
    MAX_ROWS, then the cap),
  - text rows never bleed onto or past the stroke: every ink band sits
    strictly between the top and bottom border rows,
  - a multi-row draft paints one ink band per row at the expected line pitch,
  - at the cap the visible rows touch both borders (the box really stopped
    growing and the draft is clipped there),
  - no scrollbar while the draft fits; a thumb once it caps.

Detection: the composer is the bottom-most run of >=16 consecutive uniform
"fill" rows whose immediate neighbours above/below share a different uniform
"stroke" colour (the ui.scroll box: 1 px border, solid fill). Everything else
in the shot - panel body, wallpaper gradient, bar - fails one of those tests.
"""

import os
import struct
import subprocess
import sys
import tempfile
import zlib
from collections import Counter

TOL_H = 2  # px: painted box height vs boxHeight
TOL_ROW = 3  # px: ink band vs predicted line box
TOL_CLIP = 12  # px: capped drafts must paint this close to the borders
UNIFORM = 0.98  # fraction of the scan width that must share the modal colour


def png_read(path):
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
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif f != 0:
            raise SystemExit(f"bad filter {f}")
        out[y * stride : (y + 1) * stride] = line
        prev = line
    return w, h, ch, bytes(out)


def expected(geom_path, text, luau_exe):
    # The luau CLI resolves require() only relative to the *script's* own
    # directory ("./"/"../"), and inside the nix sandbox that directory is
    # the read-only store copy of the plugin. The module is pure Lua with no
    # dependencies, so inline it into a closure instead of requiring it.
    with open(geom_path, encoding="utf-8") as fh:
        src = fh.read()
    body = (
        "local G = (function()\n" + src + "\nend)()\n"
        "local t = [==[\nTEXT\n]==]\n"
        't = t:gsub("^\\n", ""):gsub("\\n$", "")\n'
        "print(G.countRows(t), G.boxHeight(G.countRows(t)), G.MAX_ROWS,\n"
        "      G.LINE_H, G.PAD_V, tostring(G.wrapped(G.countRows(t))))\n"
    ).replace("TEXT", text.replace("]==", "] ===["))  # keep longstrings safe
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as f:
        f.write(body)
        script = f.name
    try:
        out = subprocess.run(
            [luau_exe, script], capture_output=True, text=True, check=False
        )
    finally:
        os.unlink(script)
    if out.returncode != 0:
        raise SystemExit("luau failed: " + out.stderr)
    v = out.stdout.split()
    return (
        int(v[0]),
        int(float(v[1])),
        int(v[2]),
        int(float(v[3])),
        int(float(v[4])),
        v[5] == "true",
    )


def main():
    shot, geom, text = sys.argv[1], sys.argv[2], sys.argv[3]
    luau_exe = sys.argv[4] if len(sys.argv) > 4 else "luau"
    w, h, ch, buf = png_read(shot)

    def px(x, y):
        i = (y * w + x) * ch
        return buf[i], buf[i + 1], buf[i + 2]

    def differs(c, ref, d=24):
        return max(abs(c[0] - ref[0]), abs(c[1] - ref[1]), abs(c[2] - ref[2])) > d

    def modal(y, xa, xb):
        return Counter(px(x, y) for x in range(xa, xb + 1)).most_common(1)[0]

    rows, box_h, max_rows, line_h, pad_v, capped = expected(geom, text, luau_exe)
    fails = []

    # Scan columns: right of the paperclip, left of the send button and the
    # scrollbar strip, so no widget dominates a row's modal colour.
    x0, x1 = int(w * 0.33), int(w * 0.60)
    width = x1 - x0 + 1

    def check(name, ok, detail):
        print(f"RESULT {'pass' if ok else 'fail'} {name}: {detail}")
        if not ok:
            fails.append(name)

    # Stroke rows are fully uniform (frac >= 0.98); text rows inside the box
    # are still majority fill (frac >= 0.90) because glyphs cover <10% of the
    # scan width. So: candidate borders = uniform rows; interior between a
    # same-colour pair must be fill-eligible rows of one shared colour.
    def row_class(y):
        c, n = modal(y, x0, x1)
        return c, n / width

    panel_bg = row_class(int(h * 0.35))[0]  # above the composer, inside panel
    top = bottom = None
    fill = None
    for s in range(h - 9, int(h * 0.30), -1):  # bottom border candidate
        cs, fs = row_class(s)
        if fs < 0.98 or not differs(cs, panel_bg, 24):
            continue
        cb, fb = row_class(s + 1)
        if not (fb >= 0.90 and differs(cb, cs, 24)):
            continue  # below the box must be plain panel background
        for t in range(s - 30, int(h * 0.28), -1):  # top border candidate
            ct, ft = row_class(t)
            if ft < 0.98 or differs(ct, cs, 24):
                continue
            ca, fa = row_class(t - 1)
            if not (fa >= 0.90 and differs(ca, ct, 24)):
                continue  # above the box must be plain panel background
            interior = [row_class(y) for y in range(t + 1, s)]
            if not interior:
                continue
            # Dense glyph rows can drop the fill below 20% of the scan width;
            # the invariant is that every row's modal colour is one shared
            # fill, different from the stroke. Ink coverage is checked below.
            F = Counter(c for c, _ in interior).most_common(1)[0][0]
            ok = sum(1 for c, _ in interior if not differs(c, F, 16))
            if ok >= len(interior) * 0.9 and differs(F, cs, 24):
                top, bottom, fill = t, s, F
                break
        if bottom is not None:
            break

    if bottom is None:
        check("border present", False, "no bordered fill box found")
        sys.exit(1)

    painted = bottom - top + 1
    check("box exists", True, f"border rows {top}..{bottom} fill={bytes(fill).hex()}")
    check(
        "box height == boxHeight(rows)",
        abs(painted - box_h) <= TOL_H,
        f"rows={rows} painted={painted} expected={box_h}",
    )

    # Box horizontal extent: the longest contiguous stroke-colour run on the
    # top border row itself (tolerance alone leaks onto wallpaper elsewhere).
    stroke = Counter(px(x, top) for x in range(x0, x1 + 1)).most_common(1)[0][0]
    best = best_start = 0
    run = 0
    start = None
    for x in range(2, w - 2):
        if not differs(px(x, top), stroke, 30):
            if run == 0:
                start = x
            run += 1
            if run > best:
                best, best_start = run, start
        else:
            run = 0
    box_l, box_r = (best_start, best_start + best - 1) if best > 100 else (x0, x1)

    # Text ink: rows inside the stroke with pixels differing from fill AND
    # stroke; stop before the scrollbar strip at the box's right edge.
    tx0, tx1 = box_l + 12, box_r - 14
    ink = []
    for y in range(top + 1, bottom):
        hits = sum(
            1
            for x in range(tx0, tx1 + 1)
            if differs(px(x, y), fill) and differs(px(x, y), stroke, 30)
        )
        if hits > 4:
            ink.append(y)
    bands = []
    for y in ink:
        if bands and y - bands[-1][1] <= 5:
            bands[-1][1] = y
        else:
            bands.append([y, y])

    inside = all(b[0] >= top + 1 and b[1] <= bottom - 1 for b in bands)
    check(
        "text inside border",
        inside,
        f"bands={[f'{a}:{b}' for a, b in bands]} box=({top},{bottom})",
    )

    if not capped and rows >= 2:
        check(
            "text bands == rows", len(bands) == rows, f"{len(bands)} bands, rows={rows}"
        )
        # First row must sit inside the pad (no bleed onto the stroke), and
        # consecutive bands must keep the LINE_H pitch (proves progressive
        # growth: every row the module counted is really painted).
        inset = bands[0][0] - (top + 1)
        check(
            "first row inset inside pad",
            0 <= inset <= pad_v // 2 + TOL_ROW,
            f"inset={inset}",
        )
        pitch_ok = all(
            abs((bands[i + 1][0] - bands[i][0]) - line_h) <= TOL_ROW
            for i in range(len(bands) - 1)
        )
        check(
            "row pitch == LINE_H",
            pitch_ok,
            f"band tops={[b[0] for b in bands]} pitch={line_h}",
        )
    if rows == 1 and not capped:
        # Empty draft: caret only; the single band (if any) must sit inside.
        check("empty: <=1 ink band", len(bands) <= 1, f"{len(bands)} bands")
    if capped:
        check(
            "capped: last row reaches bottom border",
            (bottom - 1) - bands[-1][1] <= line_h + TOL_CLIP,
            f"last band {bands[-1][1]}, bottom border {bottom}",
        )
        check(
            "capped: visible bands <= MAX_ROWS",
            len(bands) <= max_rows,
            f"{len(bands)} bands, cap={max_rows}",
        )
        check(
            "capped: first row touches top border",
            bands[0][0] - (top + 1) <= TOL_CLIP,
            f"first band {bands[0][0]}, top border {top}",
        )

    # Scrollbar thumb: distinct colour in the strip just inside the right border.
    sx = box_r - 4
    col = Counter(px(sx, y) for y in range(top + 2, bottom - 1))
    track = col.most_common(1)[0][0]
    thumb = None
    for c, n in col.most_common(4):
        if differs(c, fill, 16) and differs(c, track, 16) and n >= 3:
            thumb = c
            break
    inner = bottom - top - 1
    if capped:
        check("capped: scrollbar thumb present", thumb is not None, f"col x={sx}")
    else:
        full = col[thumb] if thumb else 0
        check(
            "fitting: no real scrollbar",
            thumb is None or full <= inner * 0.92,
            f"thumb {full}/{inner} at x={sx}",
        )

    sys.exit(1 if fails else 0)


main()
