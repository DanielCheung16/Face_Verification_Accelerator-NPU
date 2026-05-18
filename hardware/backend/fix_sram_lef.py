#!/usr/bin/env python3
"""
fix_sram_lef.py — Strip the M3/M4 OBS from the synthetic OpenRAM SRAM LEFs.

Problem:
  The synthetic OpenRAM LEFs (sram_psum_a / sram_psum_b) carry a conservative
  full-macro obstruction on metal3 AND metal4.  The dout pins live on metal3,
  sandwiched between the M3 OBS strips, with M4 fully blocked above — so no
  legal via3/M4 escape path exists.  NanoRoute is forced to route through the
  obstructions → ~480 SHORT/SPACING DRC violations at both SRAMs.

Fix:
  These are behavioural SRAM models with no real internal M3/M4 routing; the
  M3/M4 OBS is an over-conservative placeholder.  Remove the M3 and M4 OBS
  blocks (keep M1/M2 — deep internal layers).  The router can then place via3
  on the M3 dout pins and route over the macro on M4 normally.

  Pins are unchanged; only the OBS section is edited.

Output: <name>_fixed.lef alongside each source LEF.
"""

import re
from pathlib import Path

SRAMS = [
    "sram_lef/sram_psum_a_1rw1r0w_40_512_freepdk45.lef",
    "sram_lef/sram_psum_b_1rw0r0w_40_512_freepdk45.lef",
]

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

    dst.write_text(text)
    print(f"  {src.name}")
    print(f"    dropped OBS layers : {', '.join(dropped) if dropped else '(none)'}")
    print(f"    wrote              : {dst.name}")

print("\nDone. Update init_lef_file in run_innovus_*.tcl to use the _fixed.lef files.")
