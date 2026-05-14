#!/usr/bin/env python3

from pathlib import Path

BASE = Path(__file__).resolve().parent

DATA_W = 8
LANES = 4
WORD_W = DATA_W * LANES
ROW = 4
COL = 4
K_MAX = 16
AO_DEPTH = 128
WGT_DEPTH = 128
OUT_BASE = AO_DEPTH // 2
WGT2_BASE = 32

M = 5
K1 = 6
N1 = 4
K2 = N1
N2 = 4


def to_i8(v):
    v = max(-128, min(127, v))
    return v


def u8(v):
    return v & 0xFF


def pack_lanes(vals):
    word = 0
    for lane, value in enumerate(vals):
        word |= u8(value) << (lane * DATA_W)
    return word


def write_hex(path, words, width):
    digits = (width + 3) // 4
    with open(path, "w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{word & ((1 << width) - 1):0{digits}x}\n")


def act_value(row, k):
    return ((row * 5 + k * 3 + 1) % 15) - 7


def w1_value(k, col):
    return ((k * 7 + col * 2 + 3) % 13) - 6


def w2_value(k, col):
    return ((k * 4 + col * 5 + 2) % 11) - 5


def conv_i8(act, wgt):
    m = len(act)
    k_size = len(act[0])
    n = len(wgt[0])
    out = [[0 for _ in range(n)] for _ in range(m)]
    for r in range(m):
        for c in range(n):
            acc = 0
            for k in range(k_size):
                acc += act[r][k] * wgt[k][c]
            out[r][c] = to_i8(acc)
    return out


def pack_activation(mem, base, mat, channels):
    tiles = (channels + LANES - 1) // LANES
    for r, row in enumerate(mat):
        for tile in range(tiles):
            vals = []
            for lane in range(LANES):
                c = tile * LANES + lane
                vals.append(row[c] if c < channels else 0)
            mem[base + r * tiles + tile] = pack_lanes(vals)


def pack_weights(mem, base, mat, n):
    n_tiles = (n + LANES - 1) // LANES
    for k, row in enumerate(mat):
        for tile in range(n_tiles):
            vals = []
            for lane in range(LANES):
                c = tile * LANES + lane
                vals.append(row[c] if c < n else 0)
            mem[base + k * n_tiles + tile] = pack_lanes(vals)


def main():
    act0 = [[act_value(r, k) for k in range(K1)] for r in range(M)]
    w1 = [[w1_value(k, c) for c in range(N1)] for k in range(K1)]
    w2 = [[w2_value(k, c) for c in range(N2)] for k in range(K2)]

    out1 = conv_i8(act0, w1)
    out2 = conv_i8(out1, w2)

    ao_mem = [0 for _ in range(AO_DEPTH)]
    wgt_mem = [0 for _ in range(WGT_DEPTH)]
    golden = [0 for _ in range(AO_DEPTH)]

    pack_activation(ao_mem, 0, act0, K1)
    pack_weights(wgt_mem, 0, w1, N1)
    pack_weights(wgt_mem, WGT2_BASE, w2, N2)
    pack_activation(golden, OUT_BASE, out2, N2)

    write_hex(BASE / "conv1x1_level3_ao_init.hex", ao_mem, WORD_W)
    write_hex(BASE / "conv1x1_level3_wgt_init.hex", wgt_mem, WORD_W)
    write_hex(BASE / "conv1x1_level3_golden.hex", golden, WORD_W)


if __name__ == "__main__":
    main()
