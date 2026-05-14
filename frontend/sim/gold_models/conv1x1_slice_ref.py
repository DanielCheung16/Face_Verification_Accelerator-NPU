#!/usr/bin/env python3
"""Golden generator for a small conv1x1 layer slice.

This script intentionally models a *synthetic* slice instead of the full
QuantFace MobileFaceNet graph.  The default case is a two-layer conv1x1 chain
using small dimensions, so RTL can verify the layer_switcher/top data path
without paying for a full-network simulation.

The arithmetic matches the current conv1x1_level3 RTL configuration:
    acc = sum(input_i8 * weight_i8) + bias
    postprocess = clamp_to_int8(acc)

The postprocess mode is still emitted in the metadata, but today the RTL config
uses multiplier=1, shift=0, zero_point=0, and residual is internally zero in
conv1x1_level3_top.  Therefore requant/residual/prelu all reduce to clamp for
the default synthetic test data.

This is not a real MobileFaceNet golden reference.  Real layer slices must come
from QuantFace + pretrained_models/.../backbone.pt, because that checkpoint
contains the quantized model state and activation ranges.
"""

import argparse
import json
from collections import namedtuple
from pathlib import Path
from typing import List, Optional


BASE = Path(__file__).resolve().parent


Conv1x1Layer = namedtuple("Conv1x1Layer", ["name", "k", "n", "mode", "wgt_base"])


def clamp_i8(v: int) -> int:
    return max(-128, min(127, v))


def u8(v: int) -> int:
    return v & 0xFF


def pack_lanes(vals: List[int], data_w: int) -> int:
    word = 0
    for lane, value in enumerate(vals):
        word |= u8(value) << (lane * data_w)
    return word


def write_hex(path: Path, words: List[int], width: int) -> None:
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    with path.open("w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{word & mask:0{digits}x}\n")


def write_json(path: Path, data: object) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def synthetic_act(m: int, k: int) -> List[List[int]]:
    return [[((r * 5 + c * 3 + 1) % 15) - 7 for c in range(k)] for r in range(m)]


def synthetic_weight(k: int, n: int, seed: int) -> List[List[int]]:
    return [[((r * (7 + seed) + c * (2 + seed) + 3) % 13) - 6 for c in range(n)]
            for r in range(k)]


def conv1x1_i8(act: List[List[int]], wgt: List[List[int]], bias: Optional[List[int]] = None) -> List[List[int]]:
    m = len(act)
    k = len(act[0])
    n = len(wgt[0])
    out = [[0 for _ in range(n)] for _ in range(m)]
    for r in range(m):
        for c in range(n):
            acc = bias[c] if bias is not None else 0
            for kk in range(k):
                acc += act[r][kk] * wgt[kk][c]
            out[r][c] = clamp_i8(acc)
    return out


def pack_activation(mem: List[int], base: int, mat: List[List[int]], channels: int, lanes: int, data_w: int) -> None:
    tiles = (channels + lanes - 1) // lanes
    for r, row in enumerate(mat):
        for tile in range(tiles):
            vals = []
            for lane in range(lanes):
                c = tile * lanes + lane
                vals.append(row[c] if c < channels else 0)
            mem[base + r * tiles + tile] = pack_lanes(vals, data_w)


def pack_weights(mem: List[int], base: int, mat: List[List[int]], n: int, lanes: int, data_w: int) -> None:
    n_tiles = (n + lanes - 1) // lanes
    for k, row in enumerate(mat):
        for tile in range(n_tiles):
            vals = []
            for lane in range(lanes):
                c = tile * lanes + lane
                vals.append(row[c] if c < n else 0)
            mem[base + k * n_tiles + tile] = pack_lanes(vals, data_w)


def build_default_layers(args: argparse.Namespace) -> List[Conv1x1Layer]:
    l0_wgt_words = args.k1 * ((args.n1 + args.lanes - 1) // args.lanes)
    return [
        Conv1x1Layer("conv1x1_residual_quant", args.k1, args.n1, "MODE_RESIDUAL", 0),
        Conv1x1Layer("conv1x1_prelu_quant", args.n1, args.n2, "MODE_PRELU", l0_wgt_words),
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a small conv1x1 slice golden reference")
    parser.add_argument("--out-dir", type=Path, default=BASE)
    parser.add_argument("--prefix", default="conv1x1_slice")
    parser.add_argument("--data-w", type=int, default=8)
    parser.add_argument("--lanes", type=int, default=4)
    parser.add_argument("--ao-depth", type=int, default=128)
    parser.add_argument("--wgt-depth", type=int, default=128)
    parser.add_argument("--m", type=int, default=5)
    parser.add_argument("--k1", type=int, default=6)
    parser.add_argument("--n1", type=int, default=4)
    parser.add_argument("--n2", type=int, default=4)
    args = parser.parse_args()

    word_w = args.data_w * args.lanes
    out_base = args.ao_depth // 2
    layers = build_default_layers(args)

    act0 = synthetic_act(args.m, args.k1)

    w1 = synthetic_weight(args.k1, args.n1, seed=0)
    w2 = synthetic_weight(args.n1, args.n2, seed=2)

    out1 = conv1x1_i8(act0, w1)
    out2 = conv1x1_i8(out1, w2)

    ao_mem = [0 for _ in range(args.ao_depth)]
    wgt_mem = [0 for _ in range(args.wgt_depth)]
    golden = [0 for _ in range(args.ao_depth)]

    pack_activation(ao_mem, 0, act0, args.k1, args.lanes, args.data_w)
    pack_weights(wgt_mem, layers[0].wgt_base, w1, args.n1, args.lanes, args.data_w)
    pack_weights(wgt_mem, layers[1].wgt_base, w2, args.n2, args.lanes, args.data_w)
    pack_activation(golden, out_base, out2, args.n2, args.lanes, args.data_w)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_hex(args.out_dir / f"{args.prefix}_ao_init.hex", ao_mem, word_w)
    write_hex(args.out_dir / f"{args.prefix}_wgt_init.hex", wgt_mem, word_w)
    write_hex(args.out_dir / f"{args.prefix}_golden.hex", golden, word_w)
    write_json(args.out_dir / f"{args.prefix}_meta.json", {
        "data_w": args.data_w,
        "lanes": args.lanes,
        "word_w": word_w,
        "ao_depth": args.ao_depth,
        "wgt_depth": args.wgt_depth,
        "out_base": out_base,
        "m": args.m,
        "layers": [layer._asdict() for layer in layers],
        "files": {
            "ao_init": f"{args.prefix}_ao_init.hex",
            "wgt_init": f"{args.prefix}_wgt_init.hex",
            "golden": f"{args.prefix}_golden.hex",
        },
    })

    print(f"[conv1x1_slice_ref] wrote {args.prefix}_*.hex to {args.out_dir}")


if __name__ == "__main__":
    main()
