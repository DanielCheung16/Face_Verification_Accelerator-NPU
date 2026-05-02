#!/usr/bin/env python3
"""
run_verify.py
Full end-to-end RTL verification: generate C-model golden files and RTL
simulation output from the same input image, then compare all 50 layers.

Run from project root:
  # Full flow (image → golden + RTL → compare):
  python3 software/eval/run_verify.py --image path/to/face.jpg

  # Skip golden regen (assume current golden/ files match layer0_in.txt):
  python3 software/eval/run_verify.py --image path/to/face.jpg --skip-golden

  # Only compare existing files (no re-running anything):
  python3 software/run_verify.py --verify-only

  # Full flow on the default test image (uses current layer0_in.txt):
  python3 software/run_verify.py
"""

import argparse
import os
import subprocess
import sys
import numpy as np
from PIL import Image

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
SIM_DIR      = os.path.join(PROJECT_ROOT, "hardware/frontend/sim")
GOLDEN_DIR   = os.path.join(PROJECT_ROOT, "software/golden")
LAYER_HEX_DIR = os.path.join(SIM_DIR, "layer_hex")
HEX_DIR      = os.path.join(SIM_DIR, "hex")

B0 = 0x00000
B1 = 0x54000
B2 = 0xA8000

LAYER_PARAMS = {
     0: {"C":  64, "H": 56, "W": 48, "offset": B1},
     1: {"C":  64, "H": 56, "W": 48, "offset": B2},
     2: {"C": 128, "H": 56, "W": 48, "offset": B1},
     3: {"C": 128, "H": 28, "W": 24, "offset": B2},
     4: {"C":  64, "H": 28, "W": 24, "offset": B1},
     5: {"C": 128, "H": 28, "W": 24, "offset": B2},
     6: {"C": 128, "H": 28, "W": 24, "offset": B0},
     7: {"C":  64, "H": 28, "W": 24, "offset": B2},
     8: {"C": 128, "H": 28, "W": 24, "offset": B1},
     9: {"C": 128, "H": 28, "W": 24, "offset": B0},
    10: {"C":  64, "H": 28, "W": 24, "offset": B1},
    11: {"C": 128, "H": 28, "W": 24, "offset": B2},
    12: {"C": 128, "H": 28, "W": 24, "offset": B0},
    13: {"C":  64, "H": 28, "W": 24, "offset": B2},
    14: {"C": 128, "H": 28, "W": 24, "offset": B1},
    15: {"C": 128, "H": 28, "W": 24, "offset": B0},
    16: {"C":  64, "H": 28, "W": 24, "offset": B1},
    17: {"C": 256, "H": 28, "W": 24, "offset": B2},
    18: {"C": 256, "H": 14, "W": 12, "offset": B0},
    19: {"C": 128, "H": 14, "W": 12, "offset": B2},
    20: {"C": 256, "H": 14, "W": 12, "offset": B1},
    21: {"C": 256, "H": 14, "W": 12, "offset": B0},
    22: {"C": 128, "H": 14, "W": 12, "offset": B1},
    23: {"C": 256, "H": 14, "W": 12, "offset": B2},
    24: {"C": 256, "H": 14, "W": 12, "offset": B0},
    25: {"C": 128, "H": 14, "W": 12, "offset": B2},
    26: {"C": 256, "H": 14, "W": 12, "offset": B1},
    27: {"C": 256, "H": 14, "W": 12, "offset": B0},
    28: {"C": 128, "H": 14, "W": 12, "offset": B1},
    29: {"C": 256, "H": 14, "W": 12, "offset": B2},
    30: {"C": 256, "H": 14, "W": 12, "offset": B0},
    31: {"C": 128, "H": 14, "W": 12, "offset": B2},
    32: {"C": 256, "H": 14, "W": 12, "offset": B1},
    33: {"C": 256, "H": 14, "W": 12, "offset": B0},
    34: {"C": 128, "H": 14, "W": 12, "offset": B1},
    35: {"C": 256, "H": 14, "W": 12, "offset": B2},
    36: {"C": 256, "H": 14, "W": 12, "offset": B0},
    37: {"C": 128, "H": 14, "W": 12, "offset": B2},
    38: {"C": 512, "H": 14, "W": 12, "offset": B1},
    39: {"C": 512, "H":  7, "W":  6, "offset": B0},
    40: {"C": 128, "H":  7, "W":  6, "offset": B2},
    41: {"C": 256, "H":  7, "W":  6, "offset": B1},
    42: {"C": 256, "H":  7, "W":  6, "offset": B0},
    43: {"C": 128, "H":  7, "W":  6, "offset": B1},
    44: {"C": 256, "H":  7, "W":  6, "offset": B2},
    45: {"C": 256, "H":  7, "W":  6, "offset": B0},
    46: {"C": 128, "H":  7, "W":  6, "offset": B2},
    47: {"C": 512, "H":  7, "W":  6, "offset": B1},
    48: {"C": 512, "H":  1, "W":  1, "offset": B0},
    49: {"C": 128, "H":  1, "W":  1, "offset": B1},
}


def hex_to_int16(h):
    v = int(h, 16)
    return v - 0x10000 if v >= 0x8000 else v


def preprocess(image_path):
    img = Image.open(image_path).convert("RGB").resize((96, 112))
    arr = (np.array(img, dtype=np.float32) - 127.5) / 128.0
    return arr.transpose(2, 0, 1)[np.newaxis]  # (1,3,112,96)


def write_layer0_in(image_path):
    inp = preprocess(image_path)
    out_path = os.path.join(GOLDEN_DIR, "layer0_in.txt")
    with open(out_path, "w") as f:
        for v in inp.flatten():
            f.write(f"{v:.6f}\n")
    print(f"[Setup] Wrote {out_path}  ({inp.size} floats)")


def run_golden():
    print("[Golden] Running gen_all_golden.py ...")
    r = subprocess.run(
        [sys.executable, "software/gen_all_golden.py"],
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    out = r.stdout.decode() + r.stderr.decode()
    if r.returncode != 0:
        sys.exit(f"[Golden] FAILED:\n{out}")
    for line in out.splitlines():
        if line.strip():
            print(f"  {line}")


def run_rtl():
    print("[RTL] Running gen_hex.py ...")
    r = subprocess.run(
        [sys.executable, "gen_hex.py"],
        cwd=SIM_DIR,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if r.returncode != 0:
        sys.exit(f"[RTL] gen_hex.py FAILED:\n{r.stderr.decode()}")

    print("[RTL] Running make top (this takes ~5 min) ...")
    r = subprocess.run(
        ["make", "top"],
        cwd=SIM_DIR,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if r.returncode != 0:
        sys.exit(f"[RTL] make top FAILED:\n{r.stderr.decode()}")
    print("[RTL] Simulation complete.")


def load_rtl_hex(layer):
    hex_file = os.path.join(LAYER_HEX_DIR, f"rtl_out_layer{layer}.hex")
    if not os.path.exists(hex_file):
        hex_file = os.path.join(HEX_DIR, "rtl_out.hex")
    if not os.path.exists(hex_file):
        return None, None
    with open(hex_file) as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("@")]
    return lines, hex_file


def verify_layer(layer):
    params  = LAYER_PARAMS[layer]
    C, H, W = params["C"], params["H"], params["W"]
    offset  = params["offset"]
    n       = C * H * W

    golden_path = os.path.join(GOLDEN_DIR, f"layer{layer}_out_fixed.txt")
    if not os.path.exists(golden_path):
        return None

    with open(golden_path) as f:
        golden = np.array([int(l.strip()) for l in f], dtype=np.int32).reshape(C, H, W)

    lines, _ = load_rtl_hex(layer)
    if lines is None:
        return None

    rtl_raw = np.array([hex_to_int16(lines[offset + i]) for i in range(n)])
    rtl_chw = rtl_raw.reshape(H, W, C).transpose(2, 0, 1)

    diffs = np.abs(rtl_chw.astype(np.int32) - golden.astype(np.int32))
    return {
        "n":      n,
        "exact":  int(np.sum(diffs == 0)),
        "within1": int(np.sum(diffs <= 1)),
        "mean":   float(np.mean(diffs)),
        "max":    int(np.max(diffs)),
    }


def print_summary(results):
    GREEN = "\033[32m"
    RED   = "\033[31m"
    RESET = "\033[0m"

    print(f"\n{'Layer':>6}  {'Exact%':>8}  {'±1%':>7}  {'MeanErr':>8}  {'MaxErr':>7}")
    print("-" * 50)
    all_pass = True
    for layer in sorted(results):
        r = results[layer]
        if r is None:
            print(f"  L{layer:02d}   {'MISSING':>8}")
            continue
        pct   = r["exact"] / r["n"] * 100
        pct1  = r["within1"] / r["n"] * 100
        color = GREEN if pct == 100.0 else RED
        all_pass = all_pass and (pct == 100.0)
        print(f"  L{layer:02d}  {color}{pct:7.2f}%{RESET}  {pct1:6.2f}%  {r['mean']:8.3f}  {r['max']:7d}")
    print("-" * 50)
    status = f"{GREEN}ALL PASS{RESET}" if all_pass else f"{RED}FAILURES DETECTED{RESET}"
    print(f"  Status: {status}\n")


def main():
    ap = argparse.ArgumentParser(description="RTL end-to-end layer verification")
    ap.add_argument("--image",        help="Input face image (triggers full flow)")
    ap.add_argument("--skip-golden",  action="store_true",
                    help="Skip gen_all_golden.py (reuse existing golden files)")
    ap.add_argument("--skip-rtl",     action="store_true",
                    help="Skip make top (reuse existing layer_hex files)")
    ap.add_argument("--verify-only",  action="store_true",
                    help="Only compare existing files, run nothing")
    ap.add_argument("--layers",       nargs="+", type=int,
                    help="Specific layers to verify (default: all 0-49)")
    args = ap.parse_args()

    if not args.verify_only:
        if args.image:
            if not os.path.exists(args.image):
                sys.exit(f"Image not found: {args.image}")
            write_layer0_in(args.image)
        else:
            layer0_in = os.path.join(GOLDEN_DIR, "layer0_in.txt")
            if not os.path.exists(layer0_in):
                sys.exit("No --image provided and layer0_in.txt not found.")
            print(f"[Setup] Using existing {layer0_in}")

        if not args.skip_golden:
            run_golden()
        else:
            print("[Golden] Skipped (--skip-golden).")

        if not args.skip_rtl:
            run_rtl()
        else:
            print("[RTL] Skipped (--skip-rtl).")

    layers = args.layers if args.layers else list(range(50))
    print(f"\n[Verify] Comparing {len(layers)} layers ...")
    results = {layer: verify_layer(layer) for layer in layers}
    print_summary(results)


if __name__ == "__main__":
    main()
