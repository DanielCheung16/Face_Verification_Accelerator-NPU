#!/usr/bin/env python3
"""
eval_rtl_similarity.py
Similarity matrix across a folder of face images.
  - C fixed model: all images (fast)
  - RTL simulation: N images per person (slow, ~5 min each)

Naming convention: {person}_{idx}.jpg  (e.g. dan_1.jpg, wil_3.jpg)

Usage:
  # C model only (fastest):
  python3 software/eval_rtl_similarity.py --dir software/python/test_image_my_new --no-rtl

  # C model all + RTL for 1 image per person (default):
  python3 software/eval_rtl_similarity.py --dir software/python/test_image_my_new

  # C model all + RTL for 2 images per person:
  python3 software/eval_rtl_similarity.py --dir software/python/test_image_my_new --rtl-per-person 2

  # Skip re-running, load from cache:
  python3 software/eval_rtl_similarity.py --dir software/python/test_image_my_new --load-cache
"""

import argparse
import json
import os
import subprocess
import sys
import numpy as np
from pathlib import Path
from PIL import Image

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = os.path.abspath(os.path.dirname(__file__) + "/..")
SIM_DIR      = os.path.join(PROJECT_ROOT, "hardware/frontend/sim")
GOLDEN_DIR   = os.path.join(PROJECT_ROOT, "software/golden")
HEX_DIR      = os.path.join(SIM_DIR, "hex")
C_FIXED_EXE  = os.path.join(PROJECT_ROOT, "software/c_model_fixed/c_inference_model_fixed")
CACHE_FILE   = os.path.join(PROJECT_ROOT, "software/embedding_cache.json")
B1           = 0x54000   # L49 linear1 output offset in SRAM


# ── Image preprocessing ────────────────────────────────────────────────────────
def preprocess(image_path):
    """Load face image → (1,3,112,96) float32 normalized."""
    img = Image.open(image_path).convert("RGB").resize((96, 112))
    arr = (np.array(img, dtype=np.float32) - 127.5) / 128.0
    return arr.transpose(2, 0, 1)[np.newaxis]


# ── C fixed model ──────────────────────────────────────────────────────────────
def run_c_fixed(image_path):
    inp = preprocess(image_path)
    q10 = np.clip(np.round(inp * 1024), -32768, 32767).astype(np.int16)
    tmp_in, tmp_out = "/tmp/_erf_in.txt", "/tmp/_erf_out.txt"
    np.savetxt(tmp_in, q10.flatten(), fmt="%d")
    r = subprocess.run([C_FIXED_EXE, tmp_in, tmp_out],
                       cwd=os.path.dirname(C_FIXED_EXE),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError(f"[CFixed] crash:\n{r.stderr.decode()}")
    return np.loadtxt(tmp_out, dtype=np.int16)


# ── RTL simulation engine ──────────────────────────────────────────────────────
def hex_to_int16(h):
    v = int(h, 16)
    return v - 0x10000 if v >= 0x8000 else v


def run_rtl(image_path):
    label = os.path.basename(image_path)
    print(f"  [RTL] {label} — writing input ...")

    inp = preprocess(image_path)
    with open(os.path.join(GOLDEN_DIR, "layer0_in.txt"), "w") as f:
        for v in inp.flatten():
            f.write(f"{v:.6f}\n")

    print(f"  [RTL] gen_hex.py ...")
    r = subprocess.run(["python3", "gen_hex.py"], cwd=SIM_DIR,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError(f"[RTL] gen_hex failed:\n{r.stderr.decode()}")

    print(f"  [RTL] make top (~5 min) ...")
    r = subprocess.run(["make", "top"], cwd=SIM_DIR,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError(f"[RTL] make top failed:\n{r.stderr.decode()}")

    hex_path = os.path.join(HEX_DIR, "rtl_out_layer49.hex")
    with open(hex_path) as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("@")]

    emb = np.array([hex_to_int16(lines[B1 + i]) for i in range(128)], dtype=np.int16)
    print(f"  [RTL] Done. norm={np.linalg.norm(emb.astype(float)):.1f}")
    return emb


# ── Cache (keyed by basename so path-portable) ─────────────────────────────────
def load_cache():
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE) as f:
            raw = json.load(f)
        out = {}
        for k, v in raw.items():
            out[k] = {
                "c":   np.array(v["c"],   dtype=np.int16) if v.get("c")   else None,
                "rtl": np.array(v["rtl"], dtype=np.int16) if v.get("rtl") else None,
            }
        return out
    return {}


def save_cache(cache):
    raw = {k: {"c":   v["c"].tolist()   if v.get("c")   is not None else None,
               "rtl": v["rtl"].tolist() if v.get("rtl") is not None else None}
           for k, v in cache.items()}
    with open(CACHE_FILE, "w") as f:
        json.dump(raw, f, indent=2)
    print(f"[Cache] Saved → {CACHE_FILE}")


# ── Display ────────────────────────────────────────────────────────────────────
GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"


def colored(val, same):
    good = val > 0.5 if same else val < 0.5
    c = GREEN if good else RED
    return f"{c}{val:7.4f}{RESET}"


def print_matrix(title, names, persons, sim):
    n = len(names)
    name_w = max(len(x) for x in names) + 1
    col_w  = 9
    width  = name_w + (col_w + 1) * n + 15
    print(f"\n{'':=^{width}}\n{title:^{width}}\n{'':=^{width}}")
    print(f"{'':>{name_w}}" + "".join(f" {nm:>{col_w-1}}" for nm in names))
    print("-" * width)
    for i, rn in enumerate(names):
        row = f"{rn:>{name_w}}"
        for j in range(n):
            row += " " + colored(sim[i, j], persons[i] == persons[j])
        row += f"  ← {persons[i]}"
        print(row)
    print("=" * width)


def print_stats(title, names, persons, sim):
    unique = sorted(set(persons))
    print(f"\n[{title}] Intra vs Inter")
    print(f"{'Person':<14} | {'Intra (same)':^28} | {'Inter (diff)':^28}")
    print("-" * 76)
    all_intra, all_inter = [], []
    for p in unique:
        si = [i for i, x in enumerate(persons) if x == p]
        di = [i for i, x in enumerate(persons) if x != p]
        intra = [sim[i][j] for i in si for j in si if i != j]
        inter = [sim[i][j] for i in si for j in di]
        all_intra += intra; all_inter += inter
        ia = f"avg {np.mean(intra):.4f}  min {np.min(intra):.4f}" if intra else "N/A"
        ie = f"avg {np.mean(inter):.4f}  max {np.max(inter):.4f}" if inter else "N/A"
        print(f"{p:<14} | {ia:<28} | {ie:<28}")
    if all_intra and all_inter:
        gap = np.mean(all_intra) - np.mean(all_inter)
        label = "GOOD ✓" if gap > 0.15 else ("MARGINAL" if gap > 0 else "BAD ✗")
        print(f"\n  Intra avg : {np.mean(all_intra):.4f}")
        print(f"  Inter avg : {np.mean(all_inter):.4f}")
        print(f"  Gap       : {gap:+.4f}  ({label})")


def print_rtl_vs_c(names, images, cache):
    rtl_imgs = [p for p in images if cache[os.path.basename(p)].get("rtl") is not None]
    if not rtl_imgs:
        return
    print(f"\n{'RTL vs C Model — Embedding Exact Match':=^70}")
    print(f"{'Image':<26} {'Match':>9} {'MaxDiff':>9} {'MeanAbsErr':>12}")
    print("-" * 60)
    for p in rtl_imgs:
        k = os.path.basename(p)
        c_emb, r_emb = cache[k]["c"], cache[k]["rtl"]
        diffs = np.abs(c_emb.astype(np.int32) - r_emb.astype(np.int32))
        exact = int(np.sum(diffs == 0))
        print(f"{k:<26} {exact:>6}/128 {int(np.max(diffs)):>9} {np.mean(diffs):>12.4f}")
    print("=" * 70)


# ── Main ───────────────────────────────────────────────────────────────────────
def cosine(a, b):
    a, b = a.astype(np.float64), b.astype(np.float64)
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(np.dot(a, b) / d) if d > 0 else 0.0


def build_sim_matrix(images, cache, key):
    n = len(images)
    m = np.zeros((n, n))
    for i in range(n):
        for j in range(n):
            ki = os.path.basename(images[i])
            kj = os.path.basename(images[j])
            ei = cache[ki].get(key)
            ej = cache[kj].get(key)
            if ei is not None and ej is not None:
                m[i, j] = cosine(ei, ej)
    return m


def main():
    ap = argparse.ArgumentParser(description="RTL + C model similarity matrix on a photo folder")
    ap.add_argument("--dir", default="software/python/test_image_my_new",
                    help="folder of face images (default: test_image_my_new)")
    ap.add_argument("--no-rtl", action="store_true",
                    help="skip RTL simulation, C model only")
    ap.add_argument("--rtl-per-person", type=int, default=1,
                    help="RTL runs per person (default 1, ~5 min each)")
    ap.add_argument("--load-cache", action="store_true",
                    help="load cached embeddings (skip re-running)")
    ap.add_argument("--save-cache", action="store_true",
                    help="save embeddings to cache after running")
    args = ap.parse_args()

    img_dir = os.path.abspath(args.dir)
    images = sorted(str(p) for p in Path(img_dir).glob("*.jpg"))
    images += sorted(str(p) for p in Path(img_dir).glob("*.png"))
    if not images:
        sys.exit(f"No images found in {img_dir}")

    names   = [os.path.basename(p) for p in images]
    stems   = [Path(p).stem for p in images]
    persons = [s.rsplit("_", 1)[0] for s in stems]
    unique_persons = sorted(set(persons))

    print(f"Images : {len(images)}")
    print(f"People : {unique_persons}")
    if not args.no_rtl:
        total_rtl = len(unique_persons) * args.rtl_per_person
        print(f"RTL    : {args.rtl_per_person}/person × {len(unique_persons)} people "
              f"= {total_rtl} runs (~{total_rtl*5} min)\n")
    else:
        print()

    # Decide which images get RTL
    rtl_targets = set()
    if not args.no_rtl:
        for p in unique_persons:
            person_imgs = [images[i] for i, x in enumerate(persons) if x == p]
            for img in person_imgs[:args.rtl_per_person]:
                rtl_targets.add(img)

    cache = load_cache() if args.load_cache else {}

    # Ensure all keys exist
    for img in images:
        k = os.path.basename(img)
        if k not in cache:
            cache[k] = {"c": None, "rtl": None}

    # ── C model ──
    print("── C Fixed Model ──────────────────────────────")
    for i, img in enumerate(images):
        k = os.path.basename(img)
        if cache[k]["c"] is None:
            print(f"  [{i+1:2d}/{len(images)}] {k}")
            cache[k]["c"] = run_c_fixed(img)
        else:
            print(f"  [{i+1:2d}/{len(images)}] {k}  (cached)")

    # ── RTL ──
    if rtl_targets:
        print(f"\n── RTL Simulation ({len(rtl_targets)} images) ──────────────────")
        for img in sorted(rtl_targets):
            k = os.path.basename(img)
            if cache[k]["rtl"] is None:
                cache[k]["rtl"] = run_rtl(img)
            else:
                print(f"  {k}  (cached)")

    if args.save_cache or args.load_cache:
        save_cache(cache)

    # ── C model matrix ──
    sim_c = build_sim_matrix(images, cache, "c")
    print_matrix("C Fixed Model — Cosine Similarity", names, persons, sim_c)
    print_stats("C Fixed", names, persons, sim_c)

    # ── RTL matrix (if any) ──
    rtl_done = [img for img in images
                if cache[os.path.basename(img)].get("rtl") is not None]
    if rtl_done:
        sim_rtl = build_sim_matrix(images, cache, "rtl")
        rtl_names   = [os.path.basename(p) for p in images]
        rtl_persons = persons
        print_matrix("RTL Simulation — Cosine Similarity", rtl_names, rtl_persons, sim_rtl)
        print_stats("RTL", rtl_names, rtl_persons, sim_rtl)
        print_rtl_vs_c(names, images, cache)

        # Side-by-side gap comparison
        all_intra_c   = [sim_c[i][j]   for i in range(len(images))
                          for j in range(len(images))
                          if i != j and persons[i] == persons[j]]
        all_inter_c   = [sim_c[i][j]   for i in range(len(images))
                          for j in range(len(images)) if persons[i] != persons[j]]
        all_intra_rtl = [sim_rtl[i][j] for i in range(len(images))
                          for j in range(len(images))
                          if i != j and persons[i] == persons[j]
                          and cache[os.path.basename(images[i])].get("rtl") is not None
                          and cache[os.path.basename(images[j])].get("rtl") is not None]
        all_inter_rtl = [sim_rtl[i][j] for i in range(len(images))
                          for j in range(len(images))
                          if persons[i] != persons[j]
                          and cache[os.path.basename(images[i])].get("rtl") is not None
                          and cache[os.path.basename(images[j])].get("rtl") is not None]

        print(f"\n{'Summary Comparison':=^50}")
        print(f"{'':20} {'C Fixed':>12} {'RTL':>12}")
        print("-" * 46)
        if all_intra_c and all_intra_rtl:
            print(f"{'Intra avg':<20} {np.mean(all_intra_c):>12.4f} {np.mean(all_intra_rtl):>12.4f}")
            print(f"{'Inter avg':<20} {np.mean(all_inter_c):>12.4f} {np.mean(all_inter_rtl):>12.4f}")
            gc = np.mean(all_intra_c) - np.mean(all_inter_c)
            gr = np.mean(all_intra_rtl) - np.mean(all_inter_rtl)
            print(f"{'Gap':<20} {gc:>+12.4f} {gr:>+12.4f}")
        print("=" * 50)


if __name__ == "__main__":
    main()
