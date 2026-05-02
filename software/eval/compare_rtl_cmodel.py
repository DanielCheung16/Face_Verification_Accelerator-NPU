"""
compare_rtl_cmodel.py
Compare RTL simulation (make top) vs C fixed-point model embeddings.

Usage:
  # Run C model for all images, RTL for first N images only:
  python3 software/eval/compare_rtl_cmodel.py --images img_a.jpg img_b.jpg img_c.jpg --rtl-count 2

  # Use pre-saved embeddings (skip re-running simulations):
  python3 software/eval/compare_rtl_cmodel.py --images img_a.jpg img_b.jpg --load-cache

  # Only C model (no RTL):
  python3 software/eval/compare_rtl_cmodel.py --images img_a.jpg img_b.jpg --no-rtl
"""

import os
import sys
import argparse
import subprocess
import json
import numpy as np
from PIL import Image

# ============================================================
# Paths
# ============================================================
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
SIM_DIR      = os.path.join(PROJECT_ROOT, "hardware/frontend/sim")
GOLDEN_DIR   = os.path.join(PROJECT_ROOT, "software/golden")
HEX_DIR      = os.path.join(SIM_DIR, "hex")
C_FIXED_EXE  = os.path.join(PROJECT_ROOT, "software/c_model_fixed/c_inference_model_fixed")
CACHE_FILE   = os.path.join(PROJECT_ROOT, "software/embedding_cache.json")

B1 = 0x54000   # L49 (linear1) wr_buf = B1


# ============================================================
# Helpers
# ============================================================
def hex_to_signed_int16(h):
    val = int(h, 16)
    return val - 0x10000 if val >= 0x8000 else val


def cosine_similarity(v1, v2):
    a = v1.astype(np.float64)
    b = v2.astype(np.float64)
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    return float(np.dot(a, b) / denom) if denom > 0 else 0.0


def preprocess_image(image_path):
    """Load face image → (1,3,112,96) float32 CHW, normalized."""
    img = Image.open(image_path).convert("RGB").resize((96, 112))
    arr = (np.array(img, dtype=np.float32) - 127.5) / 128.0  # HWC
    return arr.transpose(2, 0, 1)[np.newaxis]  # (1,3,112,96)


# ============================================================
# C Fixed-Point Model Engine
# ============================================================
class CFixedEngine:
    """Runs c_inference_model_fixed and returns 128-dim int16 embedding."""

    def __init__(self):
        if not os.path.exists(C_FIXED_EXE):
            raise FileNotFoundError(f"C fixed model not found: {C_FIXED_EXE}")
        print(f"[CFixed] Using {C_FIXED_EXE}")

    def get_embedding(self, image_path):
        inp = preprocess_image(image_path)  # (1,3,112,96) float
        inp_q10 = np.clip(np.round(inp * 1024), -32768, 32767).astype(np.int16)

        tmp_in  = "/tmp/_cfix_in.txt"
        tmp_out = "/tmp/_cfix_out.txt"
        np.savetxt(tmp_in, inp_q10.flatten(), fmt="%d")

        result = subprocess.run(
            [C_FIXED_EXE, tmp_in, tmp_out],
            cwd=os.path.dirname(C_FIXED_EXE),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
        )
        if result.returncode != 0:
            raise RuntimeError(f"[CFixed] crash:\n{result.stderr}")

        emb = np.loadtxt(tmp_out, dtype=np.int16)
        return emb  # 128-dim int16


# ============================================================
# RTL Engine
# ============================================================
class RTLEngine:
    """
    Runs full RTL simulation via make top.
    For each image:
      1. Write layer0_in.txt (CHW float)
      2. python3 gen_hex.py
      3. make top
      4. Read rtl_out_layer49.hex at B1 offset → 128 int16
    """

    def get_embedding(self, image_path):
        label = os.path.basename(image_path)
        print(f"[RTL] Simulating for {label} ...")

        # Step 1: write layer0_in.txt
        inp = preprocess_image(image_path)  # (1,3,112,96) float
        layer0_in_path = os.path.join(GOLDEN_DIR, "layer0_in.txt")
        with open(layer0_in_path, "w") as f:
            for v in inp.flatten():
                f.write(f"{v:.6f}\n")

        # Step 2: generate hex files
        r = subprocess.run(
            ["python3", "gen_hex.py"], cwd=SIM_DIR,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
        )
        if r.returncode != 0:
            raise RuntimeError(f"[RTL] gen_hex.py failed:\n{r.stderr}")

        # Step 3: RTL simulation
        print(f"[RTL] Running make top (this takes ~5 min) ...")
        r = subprocess.run(
            ["make", "top"], cwd=SIM_DIR,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
        )
        if r.returncode != 0:
            raise RuntimeError(f"[RTL] make top failed:\n{r.stderr}")

        # Step 4: extract L49 embedding from hex
        hex_path = os.path.join(HEX_DIR, "rtl_out.hex")
        if not os.path.exists(hex_path):
            raise FileNotFoundError(f"[RTL] Output hex not found: {hex_path}")

        with open(hex_path) as f:
            lines = [l.strip() for l in f if l.strip() and not l.startswith("@")]

        emb = np.array(
            [hex_to_signed_int16(lines[B1 + i]) for i in range(128)],
            dtype=np.int16
        )
        print(f"[RTL] Done. Embedding norm = {np.linalg.norm(emb.astype(float)):.1f}")
        return emb  # 128-dim int16


# ============================================================
# Embedding Cache (to avoid re-running slow simulations)
# ============================================================
def load_cache():
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE) as f:
            raw = json.load(f)
        return {k: {"c": np.array(v["c"], dtype=np.int16),
                    "rtl": np.array(v["rtl"], dtype=np.int16) if v.get("rtl") else None}
                for k, v in raw.items()}
    return {}


def save_cache(cache):
    raw = {k: {"c": v["c"].tolist(),
               "rtl": v["rtl"].tolist() if v.get("rtl") is not None else None}
           for k, v in cache.items()}
    with open(CACHE_FILE, "w") as f:
        json.dump(raw, f, indent=2)
    print(f"[Cache] Saved to {CACHE_FILE}")


# ============================================================
# Similarity Table
# ============================================================
def print_similarity_table(images, cache):
    names = [os.path.basename(p) for p in images]
    n = len(names)

    print("\n" + "=" * 90)
    print("COSINE SIMILARITY MATRIX — C Fixed Model")
    print("=" * 90)
    header = f"{'':>24}" + "".join(f"{nm:>24}" for nm in names)
    print(header)
    for i in range(n):
        row = f"{names[i]:>24}"
        for j in range(n):
            ki, kj = images[i], images[j]
            if cache[ki]["c"] is not None and cache[kj]["c"] is not None:
                sim = cosine_similarity(cache[ki]["c"], cache[kj]["c"])
                row += f"{sim:>24.4f}"
            else:
                row += f"{'N/A':>24}"
        print(row)

    # RTL table if any available
    rtl_available = [p for p in images if cache[p].get("rtl") is not None]
    if rtl_available:
        print("\n" + "=" * 90)
        print("COSINE SIMILARITY MATRIX — RTL Simulation")
        print("=" * 90)
        print(header)
        for i in range(n):
            row = f"{names[i]:>24}"
            for j in range(n):
                ki, kj = images[i], images[j]
                ri, rj = cache[ki].get("rtl"), cache[kj].get("rtl")
                if ri is not None and rj is not None:
                    sim = cosine_similarity(ri, rj)
                    row += f"{sim:>24.4f}"
                else:
                    row += f"{'—':>24}"
            print(row)

        # RTL vs C model embedding comparison
        print("\n" + "=" * 90)
        print("RTL vs C MODEL — Embedding Exact Match")
        print("=" * 90)
        print(f"{'Image':<30} {'Exact Match':>12} {'Max Diff':>10} {'Mean AbsErr':>12}")
        print("-" * 70)
        for p in rtl_available:
            c_emb   = cache[p]["c"]
            rtl_emb = cache[p]["rtl"]
            diffs = np.abs(c_emb.astype(np.int32) - rtl_emb.astype(np.int32))
            exact = int(np.sum(diffs == 0))
            print(f"{os.path.basename(p):<30} {exact:>9}/128 {int(np.max(diffs)):>10} {np.mean(diffs):>12.4f}")

    print("=" * 90 + "\n")


# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser(description="Compare RTL vs C fixed-point model embeddings")
    parser.add_argument("--images", nargs="+", required=True,
                        help="Paths to face images (JPG/PNG)")
    parser.add_argument("--rtl-count", type=int, default=0,
                        help="Number of images to run through RTL simulation (0 = none, slow)")
    parser.add_argument("--no-rtl", action="store_true",
                        help="Skip RTL simulation entirely")
    parser.add_argument("--load-cache", action="store_true",
                        help="Load cached embeddings from embedding_cache.json")
    parser.add_argument("--save-cache", action="store_true",
                        help="Save computed embeddings to embedding_cache.json")
    args = parser.parse_args()

    images = [os.path.abspath(p) for p in args.images]
    for p in images:
        if not os.path.exists(p):
            print(f"Error: image not found: {p}")
            sys.exit(1)

    cache = load_cache() if args.load_cache else {}

    # Initialize engines
    c_engine = CFixedEngine()
    rtl_engine = None if args.no_rtl else RTLEngine()

    rtl_count = 0 if args.no_rtl else args.rtl_count

    for i, img_path in enumerate(images):
        key = img_path
        if key not in cache:
            cache[key] = {"c": None, "rtl": None}

        # C model
        if cache[key]["c"] is None:
            print(f"\n[{i+1}/{len(images)}] C model: {os.path.basename(img_path)}")
            cache[key]["c"] = c_engine.get_embedding(img_path)
            print(f"  → embedding[0:4] = {cache[key]['c'][:4]}")

        # RTL (only for first rtl_count images)
        if cache[key]["rtl"] is None and rtl_engine and i < rtl_count:
            print(f"\n[{i+1}/{len(images)}] RTL: {os.path.basename(img_path)}")
            cache[key]["rtl"] = rtl_engine.get_embedding(img_path)
            print(f"  → embedding[0:4] = {cache[key]['rtl'][:4]}")

    if args.save_cache or args.load_cache:
        save_cache(cache)

    print_similarity_table(images, cache)


if __name__ == "__main__":
    main()
