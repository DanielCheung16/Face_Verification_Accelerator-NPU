import sys
from pathlib import Path

import numpy as np


BASE_DIR = Path(__file__).resolve().parent


def int_to_hex(value, width):
    mask = (1 << width) - 1
    return f"{int(value) & mask:0{width // 4}x}"


def write_flat_hex(path, values, width):
    with open(path, "w") as f:
        for value in values:
            f.write(int_to_hex(value, width) + "\n")


def matmul_full(m_size, k_size, n_size):
    rng = np.random.RandomState(392)

    acts = rng.randint(-8, 8, size=(m_size, k_size)).astype(np.int8)
    wgts = rng.randint(-8, 8, size=(k_size, n_size)).astype(np.int8)
    gold = acts.astype(np.int32) @ wgts.astype(np.int32)

    write_flat_hex(BASE_DIR / "array_level2_activation.hex", acts.reshape(-1), 8)
    write_flat_hex(BASE_DIR / "array_level2_weight.hex", wgts.reshape(-1), 8)
    write_flat_hex(BASE_DIR / "array_level2_golden.hex", gold.reshape(-1), 32)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        matmul_full(7, 512, 128)
    elif len(sys.argv) == 4:
        matmul_full(
            int(sys.argv[1]),
            int(sys.argv[2]),
            int(sys.argv[3]),
        )
    else:
        raise SystemExit("usage: array_level2_golden_ref.py [M K N]")
