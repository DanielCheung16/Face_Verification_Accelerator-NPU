#!/usr/bin/env python3
"""
fix_sram_lef.py — Patch the synthetic OpenRAM SRAM LEFs for clean P&R.

Two fixes are applied to each LEF:

(1) Strip M3/M4 OBS
  The OpenRAM LEFs carry a conservative full-macro obstruction on metal3 AND
  metal4.  The dout pins live on metal3, sandwiched between the M3 OBS strips
  with M4 fully blocked above — so no legal via3/M4 escape path exists and
  NanoRoute is forced through the obstructions (~480 SHORT/SPACING DRCs).
  These behavioural SRAM models have no real internal M3/M4 routing, so the
  M3/M4 OBS is an over-conservative placeholder → removed (M1/M2 kept).

(2) Snap all coordinates to the manufacturing grid (0.005 um)
  OpenRAM emits some pin RECT coordinates off-grid (e.g. act_buf din0 pin
  y = 1.0375 / 1.1725 → IMPLF-82, and a downstream OFFGRID DRC on the clock
  net routed to that pin).  Every RECT / SIZE / ORIGIN coordinate is rounded
  to the nearest 0.005 um grid point.

Output: <name>_fixed.lef alongside each source LEF.
"""

import re
from pathlib import Path

GRID = 0.005   # FreePDK45 MANUFACTURINGGRID

SRAMS = [
    "sram_lef/sram_psum_a_1rw1r0w_40_512_freepdk45.lef",
    "sram_lef/sram_psum_b_1rw0r0w_40_512_freepdk45.lef",
    "sram_lef/v3/sram_act_buf_1rw0r0w_192_64_freepdk45.lef",  # v3+ opt④
]


def snap(v):
    """Round a coordinate string to the nearest GRID point."""
    s = round(round(float(v) / GRID) * GRID, 4)
    return f"{s:g}"


def snap_line(line):
    """Snap every numeric coordinate on a RECT / SIZE line to the grid.
    Numbers are substituted IN PLACE so keywords (e.g. 'BY') and the
    original spacing are preserved exactly."""
    if not re.match(r'^\s*(RECT|SIZE)\b', line):
        return line, 0
    changed = [0]

    def repl(mo):
        orig = mo.group(0)
        s = snap(orig)
        if s != orig:
            changed[0] += 1
        return s

    new_line = re.sub(r'-?\d+\.\d+|-?\d+', repl, line)
    return new_line, changed[0]


for src_path in SRAMS:
    src = Path(src_path)
    dst = src.with_name(src.stem + "_fixed.lef")
    text = src.read_text()

    # The OBS section runs from "   OBS\n" to the next bare "   END\n".
    m = re.search(r'(   OBS\n)(.*?)(\n   END\n)', text, re.DOTALL)
    if not m:
        print(f"  WARNING: OBS section not found in {src.name}")
        continue

    obs_body = m.group(2)

    # Walk the OBS body line by line.  Keep M1/M2 LAYER blocks; drop M3/M4.
    kept_lines = []
    dropped = []
    drop_current = False
    for line in obs_body.split("\n"):
        lm = re.match(r'   LAYER  (metal\d+) ;', line)
        if lm:
            drop_current = lm.group(1) in ("metal3", "metal4")
            if drop_current:
                dropped.append(lm.group(1))
        if not drop_current:
            kept_lines.append(line)

    new_obs = m.group(1) + "\n".join(kept_lines).rstrip("\n") + m.group(3)
    text = text[:m.start()] + new_obs + text[m.end():]

    # ── grid-snap pass: every RECT / SIZE coordinate → 0.005 um grid ─────────
    snapped_total = 0
    out_lines = []
    for line in text.split("\n"):
        new_line, n = snap_line(line)
        snapped_total += n
        out_lines.append(new_line)
    text = "\n".join(out_lines)

    dst.write_text(text)
    print(f"  {src.name}")
    print(f"    dropped OBS layers : {', '.join(dropped) if dropped else '(none)'}")
    print(f"    grid-snapped coords: {snapped_total}")
    print(f"    wrote              : {dst.name}")

print("\nDone. Update init_lef_file in run_innovus_*.tcl to use the _fixed.lef files.")
