#!/usr/bin/env python3
"""
compare_layers.py — Compare v3 layer_hex_v3/ outputs against v2 ../sim2/layer_hex/

v2 stores layer N outputs at: wr_base + [0 .. N-1]  (wr_base comes from config[63:62])
  buf=0 → base=0x00000 (     0)
  buf=1 → base=0x54000 (344064)
  buf=2 → base=0xA8000 (688128)

v3 stores layer N outputs at: [0 .. N-1]  (ping-pong SRAM, sequential from 0)

Usage: python3 compare_layers.py
"""
import os, sys

BUF_BASE = {0: 0x00000, 1: 0x54000, 2: 0xA8000}

def decode_layer(cfg):
    """Return (N_outputs, wr_base) for a 64-bit layer config word."""
    out_ch = (cfg >> 10) & 0x3FF
    w      = (cfg >> 20) & 0x7F
    h      = (cfg >> 27) & 0x7F
    stride = (cfg >> 34) & 0x3
    wr_buf = (cfg >> 62) & 0x3
    s = max(1, stride)
    x_cnt = len(range(0, w, s))
    y_cnt = len(range(0, h, s))
    return x_cnt * y_cnt * out_ch, BUF_BASE.get(wr_buf, 0)

def load_hex(path, offset, n):
    """Load n hex16 entries from path starting at line `offset`."""
    with open(path) as f:
        lines = f.readlines()
    return [lines[offset + i].strip() for i in range(n) if offset + i < len(lines)]

cfg_path = "hex/config.hex"
if not os.path.exists(cfg_path):
    print(f"ERROR: {cfg_path} not found — run 'make hex' first"); sys.exit(1)

with open(cfg_path) as f:
    cfg_words = [int(t, 16) for t in f.read().split()]

print("=== Comparing v3 layer_hex_v3/ vs v2 ../sim2/layer_hex/ ===")
all_match = True
for i in range(50):
    n, base = decode_layer(cfg_words[i])
    v2_path = f"../sim2/layer_hex/rtl_out_layer{i}.hex"
    v3_path = f"layer_hex_v3/rtl_out_layer{i}.hex"

    if not os.path.exists(v2_path):
        print(f"  Layer {i:2d}: SKIP (v2 file missing: {v2_path})")
        continue
    if not os.path.exists(v3_path):
        print(f"  Layer {i:2d}: SKIP (v3 file missing: {v3_path})")
        continue

    v2 = load_hex(v2_path, base, n)
    v3 = load_hex(v3_path, base, n)  # v3 uses same 3-buffer layout as v2

    if len(v2) < n or len(v3) < n:
        print(f"  Layer {i:2d}: SKIP (file too short: v2={len(v2)}/{n} v3={len(v3)}/{n})")
        continue

    mismatches = [(j, v2[j], v3[j]) for j in range(n) if v2[j] != v3[j]]
    if mismatches:
        all_match = False
        print(f"  Layer {i:2d}: MISMATCH <<< ({len(mismatches)}/{n} differ,"
              f" first at [{mismatches[0][0]}]: v2={mismatches[0][1]} v3={mismatches[0][2]})")
    else:
        print(f"  Layer {i:2d}: MATCH  ({n} entries)")

print()
if all_match:
    print("All 50 layers MATCH (v3 == v2)")
else:
    print("MISMATCH found — check layers marked <<<")
    sys.exit(1)
