#!/usr/bin/env python3.8
"""
gen_psum_lef.py — Generate mfn_psum_sram.lef for Innovus P&R

The behavioral mfn_psum_sram (2W+3R) is implemented as two OpenRAM SRAMs:
  SRAM_A (1RW+1R, 40x512): write_a / read_a / read_c
  SRAM_B (1RW,    40x512): write_b / read_b

This script reads SRAM_A.lef to get the physical size and generates a
synthetic mfn_psum_sram.lef with:
  - MACRO name matching the synthesis netlist cell name
  - SIZE = SRAM_A width  x  (SRAM_A height * 2)   (stacked vertically)
  - Pins matching the mfn_psum_sram RTL port list

The pin layer/geometry is set to Metal3 across the full macro width as a
placeholder; real pin assignment requires custom Innovus ECO steps.
"""

import sys
import re

SRAM_A_LEF = "macro/sram_psum_a_1rw1r0w_40_512_freepdk45/sram_psum_a_1rw1r0w_40_512_freepdk45.lef"
OUTPUT_LEF  = "macro/mfn_psum_sram.lef"

# ── Parse SRAM_A size ────────────────────────────────────────────────────────
with open(SRAM_A_LEF) as f:
    src = f.read()

m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", src)
if not m:
    print("ERROR: could not parse SIZE from", SRAM_A_LEF)
    sys.exit(1)

sram_w = float(m.group(1))
sram_h = float(m.group(2))
total_w = sram_w
total_h = round(sram_h * 2, 4)   # two SRAMs stacked

print(f"SRAM_A size  : {sram_w} x {sram_h} um")
print(f"mfn_psum_sram: {total_w} x {total_h} um  (2 SRAMs stacked)")

# ── Port list ─────────────────────────────────────────────────────────────────
# Matches mfn_psum_sram RTL port declarations exactly.
ABITS  = 9
AWIDTH = 40

ports_1bit = [
    ("clk",    "INPUT",  "CLOCK"),
    ("we_a",   "INPUT",  "SIGNAL"),
    ("we_b",   "INPUT",  "SIGNAL"),
]
ports_addr = [
    ("waddr_a", "INPUT",  "SIGNAL", ABITS),
    ("waddr_b", "INPUT",  "SIGNAL", ABITS),
    ("raddr_a", "INPUT",  "SIGNAL", ABITS),
    ("raddr_b", "INPUT",  "SIGNAL", ABITS),
    ("raddr_c", "INPUT",  "SIGNAL", ABITS),
]
ports_data = [
    ("wdata_a", "INPUT",  "SIGNAL", AWIDTH),
    ("wdata_b", "INPUT",  "SIGNAL", AWIDTH),
    ("rdata_a", "OUTPUT", "SIGNAL", AWIDTH),
    ("rdata_b", "OUTPUT", "SIGNAL", AWIDTH),
    ("rdata_c", "OUTPUT", "SIGNAL", AWIDTH),
]
power_ports = [
    ("VDD", "INOUT", "POWER"),
    ("VSS", "INOUT", "GROUND"),
]

PIN_LAYER = "metal3"
PIN_H     = 0.14    # pin rect height (um)
PIN_Y_MID = total_h / 2.0

def pin_block(name, direction, use, x_frac=0.5):
    """Generate a single-bit PIN block with a small rect on metal3."""
    pin_x = round(total_w * x_frac, 4)
    rect_x0 = round(pin_x - 0.07, 4)
    rect_x1 = round(pin_x + 0.07, 4)
    rect_y0 = round(PIN_Y_MID - PIN_H / 2, 4)
    rect_y1 = round(PIN_Y_MID + PIN_H / 2, 4)
    return (
        f"  PIN {name}\n"
        f"    DIRECTION {direction} ;\n"
        f"    USE {use} ;\n"
        f"    PORT\n"
        f"      LAYER {PIN_LAYER} ;\n"
        f"        RECT {rect_x0} {rect_y0} {rect_x1} {rect_y1} ;\n"
        f"    END\n"
        f"  END {name}\n"
    )

# ── Build LEF content ─────────────────────────────────────────────────────────
lines = []
lines.append("VERSION 5.7 ;\n")
lines.append("BUSBITCHARS \"[]\" ;\n\n")
lines.append(f"MACRO mfn_psum_sram\n")
lines.append(f"  CLASS BLOCK ;\n")
lines.append(f"  ORIGIN 0.000 0.000 ;\n")
lines.append(f"  FOREIGN mfn_psum_sram 0.000 0.000 ;\n")
lines.append(f"  SIZE {total_w} BY {total_h} ;\n")
lines.append(f"  SYMMETRY X Y R90 ;\n")
lines.append(f"  SITE FreePDK45_38x28_10R_NP_162NW_34O ;\n\n")

x_step = 1.0 / (len(ports_1bit) + len(ports_addr) + len(ports_data) + len(power_ports) + 1)
x_frac = x_step

for name, direction, use in ports_1bit:
    lines.append(pin_block(name, direction, use, x_frac))
    x_frac += x_step

for name, direction, use, width in ports_addr + ports_data:
    for bit in range(width):
        lines.append(pin_block(f"{name}[{bit}]", direction, use, x_frac))
    x_frac += x_step

for name, direction, use in power_ports:
    lines.append(pin_block(name, direction, use, x_frac))
    x_frac += x_step

lines.append(f"END mfn_psum_sram\n\n")
lines.append("END LIBRARY\n")

with open(OUTPUT_LEF, "w") as f:
    f.writelines(lines)

print(f"Written : {OUTPUT_LEF}")
