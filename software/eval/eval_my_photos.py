#!/usr/bin/env python3
"""
Evaluate MobileFaceNet C-fixed model on personal photos.
Computes a cosine-similarity matrix and per-person intra/inter stats.

Usage (from project root):
  python3 software/eval/eval_my_photos.py                                    # default: c_fixed model
  python3 software/eval/eval_my_photos.py --engine pytorch                   # PyTorch instead
  python3 software/eval/eval_my_photos.py --engine c_fixed pytorch           # both side-by-side
  python3 software/eval/eval_my_photos.py --dir software/src/test_image_my_new  # custom image dir
"""
import argparse
import os
import subprocess
import sys
import numpy as np
from pathlib import Path
from PIL import Image


def preprocess_image(image_path):
    """Load, resize to 96×112, normalize → CHW float32 array."""
    img = Image.open(image_path).convert("RGB").resize((96, 112))
    arr = (np.array(img, dtype=np.float32) - 127.5) / 128.0
    return arr.transpose(2, 0, 1)[np.newaxis]  # (1, 3, 112, 96)

_EVAL_DIR    = os.path.dirname(os.path.abspath(__file__))
_SW_DIR      = os.path.join(_EVAL_DIR, "..")

IMG_DIR      = os.path.join(_SW_DIR, "src/test_image_my_new")
C_EXE        = os.path.join(_SW_DIR, "c_model/c_inference_model")
C_FIXED_EXE  = os.path.join(_SW_DIR, "c_model_fixed/c_inference_model_fixed")
C_FIXED8_EXE = os.path.join(_SW_DIR, "c_model_fixed8/c_inference_model_fixed8")
CKPT_PATH    = os.path.join(_SW_DIR, "src/068.ckpt")
F_BITS  = 10;  SCALE  = 1 << F_BITS
F8_BITS = 6;   SCALE8 = 1 << F8_BITS


# ── embedding functions ────────────────────────────────────────────────────────

def _run_c(exe, tmp_in, tmp_out):
    r = subprocess.run([exe, tmp_in, tmp_out],
                       cwd=os.path.dirname(exe),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError(f"{exe} failed:\n{r.stderr.decode().strip()}")
    emb = np.loadtxt(tmp_out, dtype=np.float32)
    for p in [tmp_in, tmp_out]:
        if os.path.exists(p): os.remove(p)
    return emb


def embed_c(image_path):
    inp = preprocess_image(image_path)
    np.savetxt("/tmp/_emc_in.txt", inp.flatten(), fmt="%.6f")
    return _run_c(C_EXE, "/tmp/_emc_in.txt", "/tmp/_emc_out.txt")


def embed_c_fixed(image_path):
    inp = preprocess_image(image_path)
    q16 = np.clip(np.round(inp * SCALE), -32768, 32767).astype(np.int16)
    np.savetxt("/tmp/_emc_f16_in.txt", q16.flatten(), fmt="%d")
    return _run_c(C_FIXED_EXE, "/tmp/_emc_f16_in.txt", "/tmp/_emc_f16_out.txt")


def embed_c_fixed8(image_path):
    inp = preprocess_image(image_path)
    q8 = np.clip(np.round(inp * SCALE8), -128, 127).astype(np.int8)
    np.savetxt("/tmp/_emc_f8_in.txt", q8.flatten(), fmt="%d")
    return _run_c(C_FIXED8_EXE, "/tmp/_emc_f8_in.txt", "/tmp/_emc_f8_out.txt")


def embed_pytorch(image_path):
    import torch
    sys.path.insert(0, os.path.join(_EVAL_DIR, "../python"))
    from model import MobileFacenet
    global _pt_net
    if "_pt_net" not in globals():
        _pt_net = MobileFacenet()
        _pt_net.eval()
        try:
            ckpt = torch.load(CKPT_PATH, map_location="cpu")
            sd = ckpt.get("net_state_dict", ckpt)
            sd = {(k[7:] if k.startswith("module.") else k): v for k, v in sd.items()}
            _pt_net.load_state_dict(sd)
        except Exception as e:
            print(f"[pytorch] weight load warning: {e}")
    import torch as _torch
    tensor = _torch.tensor(preprocess_image(image_path))
    with _torch.no_grad():
        out = _pt_net(tensor)
    return out.numpy().flatten()


ENGINES = {
    "c":        ("C Float",  embed_c),
    "c_fixed":  ("C INT16",  embed_c_fixed),
    "c_fixed8": ("C INT8",   embed_c_fixed8),
    "pytorch":  ("PyTorch",  embed_pytorch),
}


# ── similarity helpers ─────────────────────────────────────────────────────────

def cosine(a, b):
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def sim_matrix(embeddings):
    n = len(embeddings)
    m = np.zeros((n, n))
    for i in range(n):
        for j in range(n):
            m[i, j] = cosine(embeddings[i], embeddings[j])
    return m


# ── display helpers ────────────────────────────────────────────────────────────

def color(val, is_same):
    """ANSI color: green if good separation, red if bad."""
    GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"
    if is_same:
        return (GREEN if val > 0.5 else RED) + f"{val:7.4f}" + RESET
    else:
        return (GREEN if val < 0.5 else RED) + f"{val:7.4f}" + RESET


def print_matrix(sim, names, persons, engine_label):
    n = len(names)
    name_w = max(len(x) for x in names) + 1
    col_w  = 9
    title  = f" {engine_label} — Cosine Similarity Matrix "
    width  = name_w + (col_w + 1) * n + 2

    print(f"\n{'':=^{width}}")
    print(f"{title:^{width}}")
    print(f"{'':=^{width}}")

    # header
    row = f"{'':>{name_w}}"
    for nm in names:
        row += f" {nm:>{col_w-1}}"
    print(row)
    print("-" * width)

    # rows
    for i, rname in enumerate(names):
        row = f"{rname:>{name_w}}"
        for j in range(n):
            is_same = (persons[i] == persons[j])
            row += " " + color(sim[i, j], is_same)
        row += f"  ← {persons[i]}"
        print(row)

    print("=" * width)


def print_stats(sim, names, persons, engine_label):
    unique = sorted(set(persons))

    print(f"\n[{engine_label}] Per-person intra vs inter similarity")
    print(f"{'Person':<12} | {'Intra (same person)':^26} | {'Inter (diff person)':^26}")
    print("-" * 70)

    for p in unique:
        si = [i for i, x in enumerate(persons) if x == p]
        di = [i for i, x in enumerate(persons) if x != p]
        intra = [sim[i][j] for i in si for j in si if i != j]
        inter = [sim[i][j] for i in si for j in di]
        ia = f"avg {np.mean(intra):.4f}  min {np.min(intra):.4f}" if intra else "N/A"
        ie = f"avg {np.mean(inter):.4f}  max {np.max(inter):.4f}" if inter else "N/A"
        print(f"{p:<12} | {ia:<26} | {ie:<26}")

    # overall separability
    all_intra = [sim[i][j] for i in range(len(names))
                             for j in range(len(names))
                             if i != j and persons[i] == persons[j]]
    all_inter = [sim[i][j] for i in range(len(names))
                             for j in range(len(names))
                             if persons[i] != persons[j]]
    if all_intra and all_inter:
        gap = np.mean(all_intra) - np.mean(all_inter)
        print(f"\n  Overall intra avg : {np.mean(all_intra):.4f}")
        print(f"  Overall inter avg : {np.mean(all_inter):.4f}")
        print(f"  Separability gap  : {gap:+.4f}  "
              f"({'GOOD ✓' if gap > 0.15 else 'MARGINAL' if gap > 0 else 'BAD ✗'})")


# ── main ───────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Evaluate MobileFaceNet on personal photos")
    p.add_argument("--engine", nargs="+", default=["c_fixed"],
                   choices=list(ENGINES), metavar="ENGINE",
                   help=f"engines to use (default: c_fixed). choices: {list(ENGINES)}")
    p.add_argument("--dir", default=IMG_DIR, metavar="DIR",
                   help=f"image directory (default: {IMG_DIR})")
    return p.parse_args()


def main():
    args = parse_args()
    img_dir = args.dir

    images = sorted(Path(img_dir).glob("*.jpg")) + sorted(Path(img_dir).glob("*.png"))
    if not images:
        raise SystemExit(f"No images found in {img_dir}")

    names   = [p.stem for p in images]
    persons = [n.rsplit("_", 1)[0] for n in names]

    print(f"Images  : {len(images)}")
    print(f"People  : {sorted(set(persons))}")
    print(f"Engines : {args.engine}\n")

    for eng_key in args.engine:
        label, embed_fn = ENGINES[eng_key]
        print(f"─── [{label}] computing embeddings ───")

        embeddings = []
        for img in images:
            try:
                emb = embed_fn(str(img))
                embeddings.append(emb)
                print(f"  {img.name:20s}  dim={len(emb)}  norm={np.linalg.norm(emb):.4f}")
            except Exception as e:
                print(f"  {img.name}: FAILED — {e}")
                sys.exit(1)

        sim = sim_matrix(embeddings)
        print_matrix(sim, names, persons, label)
        print_stats(sim, names, persons, label)
        print()


if __name__ == "__main__":
    main()
