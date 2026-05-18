#!/usr/bin/env python3.8
"""
gen_act_buf_lef.py — Generate sram_act_buf_1rw0r0w_16_512_freepdk45.lef

This script can operate in two modes:
  1. If OpenRAM has already run (macro/sram_act_buf_*/sram_act_buf_*.lef exists):
     reads the exact SIZE from that LEF so pin placement matches physical layout.
  2. Otherwise: uses estimated dimensions derived from SRAM_B scaling
     (40x512 → 16x512; width narrows, height stays similar).

Estimated size for mode 2:
  SRAM_B (1RW, 40x512): 158.995 × 204.86 um
  act_buf (1RW, 16x512): estimated ~111 × 132 um
    Width: 16-column cell array + fixed peripheral ≈ 111 um
    Height: 512-row cell array scales slightly from SRAM_B ≈ 132 um
  Expected area: ~14 640 um² vs SRAM_B 32 571 um² (SRAM_B has more sense amps)

Pin placement follows OpenRAM FreePDK45 convention:
  din0[*] : metal3, y ≈ 1.04 um (bottom row)
  dout0[*]: metal3, y ≈ 14.66 um (second row from bottom)
  addr0[*]: metal3, distributed across right side
  clk0, csb0, web0, wmask0[*]: metal3, bottom-left cluster
  vdd, gnd : metal1 power rails (power/ground USE)

Output: macro/sram_act_buf_1rw0r0w_16_512_freepdk45.lef
"""

import os
import re
import sys

# ── Constants ──────────────────────────────────────────────────────────────────
MACRO_NAME  = "sram_act_buf_1rw0r0w_16_512_freepdk45"
OUTPUT_LEF  = f"macro/{MACRO_NAME}.lef"
MFG_GRID    = 0.005   # FreePDK45 manufacturing grid (um)
PIN_LAYER   = "metal3"

WORD_SIZE   = 16      # bits per word
ABITS       = 9       # ceil(log2(512))
MASK_BITS   = 2       # word_size / write_size = 16/8

# ── Estimated size (used when OpenRAM output not available) ────────────────────
# Derived by scaling SRAM_B (40x512, 158.995×204.86 um):
#   Width: fixed peripheral ~79 um + cell_array(16 cols × ~2 um/col) = 111 um
#   Height: 512 rows at ~0.255 um/row + decoder overhead ≈ 132 um
EST_W = 111.005
EST_H = 131.600

OPENRAM_LEF = f"macro/{MACRO_NAME}/{MACRO_NAME}.lef"

def snap(v):
    return round(round(v / MFG_GRID) * MFG_GRID, 4)

# ── Determine macro size ───────────────────────────────────────────────────────
if os.path.exists(OPENRAM_LEF):
    with open(OPENRAM_LEF) as f:
        src = f.read()
    m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", src)
    if m:
        W, H = float(m.group(1)), float(m.group(2))
        print(f"[gen_act_buf_lef] Reading size from OpenRAM output: {W} × {H} um")
    else:
        print(f"[gen_act_buf_lef] WARNING: could not parse SIZE from {OPENRAM_LEF}, using estimate")
        W, H = EST_W, EST_H
else:
    print(f"[gen_act_buf_lef] OpenRAM output not found — using estimated {EST_W} × {EST_H} um")
    print(f"  (Run: python3.8 sram_compiler.py freepdk45_sram_act_buf_16x512.py first)")
    W, H = EST_W, EST_H

# ── Pin geometry helpers ────────────────────────────────────────────────────────
PIN_W   = 0.135    # pin rect width (um, OpenRAM style)
PIN_H   = 0.135    # pin rect height (um)

# Bottom pin row (din0, wmask0, clk0, csb0, web0): y ≈ 1.04 um (local, y_local)
# dout0 row:  y ≈ 14.66 um (matches SRAM_B dout0 y_local for consistent routing)
# addr0[*]:   scattered along right side (x ≈ W - 2 um)
# power pins: top/bottom edges

Y_DIN   = snap(1.04)
Y_DOUT  = snap(14.66)
Y_CTRL  = snap(1.04)   # clk0, csb0, web0, wmask0 share bottom row with din0
Y_ADDR_START = snap(H * 0.15)   # addr pins start at 15% height, spaced up
ADDR_PITCH   = snap((H * 0.70) / max(ABITS, 1))

def pin_block(name, direction, use, px, py):
    rx0 = snap(px - PIN_W / 2)
    rx1 = snap(px + PIN_W / 2)
    ry0 = snap(py - PIN_H / 2)
    ry1 = snap(py + PIN_H / 2)
    return (
        f"   PIN {name}\n"
        f"      DIRECTION {direction} ;\n"
        f"      USE {use} ;\n"
        f"      PORT\n"
        f"         LAYER {PIN_LAYER} ;\n"
        f"         RECT {rx0} {ry0} {rx1} {ry1} ;\n"
        f"      END\n"
        f"   END {name}\n"
    )

def power_pin_block(name, use):
    """Power/ground: thin metal1 bar across full width at top or bottom."""
    y0 = 0.085 if use == "GROUND" else snap(H - 0.085)
    y1 = snap(y0 + 0.17)
    return (
        f"   PIN {name}\n"
        f"      DIRECTION INOUT ;\n"
        f"      USE {use} ;\n"
        f"      PORT\n"
        f"         LAYER metal1 ;\n"
        f"         RECT 0.085 {y0} {snap(W - 0.085)} {y1} ;\n"
        f"      END\n"
        f"   END {name}\n"
    )

# ── Build LEF ─────────────────────────────────────────────────────────────────
lines = []
lines.append(f"VERSION 5.4 ;\n")
lines.append(f"NAMESCASESENSITIVE ON ;\n")
lines.append(f"BUSBITCHARS \"[]\" ;\n")
lines.append(f"DIVIDERCHAR \"/\" ;\n")
lines.append(f"UNITS\n")
lines.append(f"  DATABASE MICRONS 2000 ;\n")
lines.append(f"END UNITS\n")
lines.append(f"MACRO {MACRO_NAME}\n")
lines.append(f"   CLASS BLOCK ;\n")
lines.append(f"   SIZE {snap(W)} BY {snap(H)} ;\n")
lines.append(f"   SYMMETRY X Y R90 ;\n")

# ── din0[0..15]: bottom row, evenly spaced ─────────────────────────────────────
din_x_start = snap(W * 0.10)
din_pitch   = snap((W * 0.55) / max(WORD_SIZE, 1))
for bit in range(WORD_SIZE):
    px = snap(din_x_start + bit * din_pitch)
    lines.append(pin_block(f"din0[{bit}]", "INPUT", "SIGNAL", px, Y_DIN))

# ── dout0[0..15]: second row, same x spacing ───────────────────────────────────
for bit in range(WORD_SIZE):
    px = snap(din_x_start + bit * din_pitch)
    lines.append(pin_block(f"dout0[{bit}]", "OUTPUT", "SIGNAL", px, Y_DOUT))

# ── addr0[0..8]: right half, distributed vertically ───────────────────────────
addr_x = snap(W * 0.82)
for bit in range(ABITS):
    py = snap(Y_ADDR_START + bit * ADDR_PITCH)
    lines.append(pin_block(f"addr0[{bit}]", "INPUT", "SIGNAL", addr_x, py))

# ── wmask0[0..1]: left side, bottom ───────────────────────────────────────────
for bit in range(MASK_BITS):
    px = snap(W * 0.03 + bit * snap(W * 0.04))
    lines.append(pin_block(f"wmask0[{bit}]", "INPUT", "SIGNAL", px, Y_CTRL))

# ── Control pins: clk0, csb0, web0 ────────────────────────────────────────────
ctrl_pins = ["clk0", "csb0", "web0"]
ctrl_uses = ["CLOCK", "SIGNAL", "SIGNAL"]
ctrl_dirs = ["INPUT",  "INPUT",  "INPUT"]
for i, (name, use, direction) in enumerate(zip(ctrl_pins, ctrl_uses, ctrl_dirs)):
    px = snap(W * 0.03 + (MASK_BITS + 1 + i) * snap(W * 0.04))
    lines.append(pin_block(name, direction, use, px, Y_CTRL))

# ── Power pins ─────────────────────────────────────────────────────────────────
lines.append(power_pin_block("vdd", "POWER"))
lines.append(power_pin_block("gnd", "GROUND"))

# ── Obstruction: full-body metal4 OBS (same pattern as psum SRAMs) ─────────────
lines.append(f"   OBS\n")
lines.append(f"      LAYER metal4 ;\n")
lines.append(f"         RECT 0.14 0.14 {snap(W - 0.14)} {snap(H - 0.14)} ;\n")
lines.append(f"   END\n")

lines.append(f"END {MACRO_NAME}\n\n")
lines.append(f"END LIBRARY\n")

os.makedirs("macro", exist_ok=True)
with open(OUTPUT_LEF, "w") as f:
    f.writelines(lines)

print(f"[gen_act_buf_lef] Written: {OUTPUT_LEF}")
print(f"  Size : {snap(W)} × {snap(H)} um  ({snap(W) * snap(H):.0f} um²)")
print(f"  Pins : din0[15:0] at y={Y_DIN}, dout0[15:0] at y={Y_DOUT}")
print(f"  Pins : addr0[8:0] at x={addr_x}, clk0/csb0/web0/wmask0[1:0] at y={Y_CTRL}")
print(f"  OBS  : metal4 full-body RECT 0.14 0.14 {snap(W-0.14)} {snap(H-0.14)}")
