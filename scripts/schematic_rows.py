#!/usr/bin/env python3
"""Reconstruct schematic 'ball | function | net' rows using word coordinates.

Linear PDF text extraction scrambles the FPGA pin tables (ball-function and the
connector net are on the same visual row but separated in reading order). This
groups words by y-position to rebuild each row, then prints rows that tie an
FPGA ball to a GPIO header net (or any net of interest).
"""
import sys, re
import fitz

PDF = "docs/QMTECH_Cyclone_V_SoC_KFB_Dual_SDRAM_Schematic_20240607_V01.pdf"
WANT = sys.argv[1] if len(sys.argv) > 1 else "GPIO_0"   # net substring filter
BALL = re.compile(r'^[A-K]?[A-Z][0-9]{1,2}$')

d = fitz.open(PDF)
for pno, page in enumerate(d):
    words = page.get_text("words")  # (x0,y0,x1,y1, word, block,line,wno)
    if not any(WANT in w[4] for w in words):
        continue
    # cluster by rounded y (rows)
    rows = {}
    for x0, y0, x1, y1, w, *_ in words:
        key = round(y0 / 6.0)        # ~6px row tolerance
        rows.setdefault(key, []).append((x0, w))
    print("===== PAGE %d =====" % pno)
    for key in sorted(rows):
        items = sorted(rows[key])
        toks = [w for _, w in items]
        line = " ".join(toks)
        if WANT in line and any(BALL.match(t) for t in toks):
            balls = [t for t in toks if BALL.match(t)]
            nets = [t for t in toks if WANT in t]
            print("  %-10s <->  %s   | full: %s" %
                  (",".join(balls), ",".join(nets), line[:95]))
