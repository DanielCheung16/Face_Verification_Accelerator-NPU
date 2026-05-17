#!/usr/bin/env python3
"""Dump conv1x1 C-reference postprocess parameters into ROM hex files."""

from pathlib import Path
import re


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_H = SCRIPT_DIR / "quantface_conv1x1_ref_data.h"
OUT_DIR = SCRIPT_DIR / "out"

LAYERS = ((0, 64), (1, 128))


def parse_array(text, name):
    match = re.search(rf"{name}\[[^\]]+\]\s*=\s*\{{(.*?)\}};", text, re.S)
    if not match:
        raise RuntimeError(f"missing array {name}")
    return [int(v) for v in re.findall(r"-?\d+", match.group(1))]


def twos(value, width):
    if value < 0:
        value = (1 << width) + value
    return value & ((1 << width) - 1)


def write_hex(path, values, width):
    digits = (width + 3) // 4
    path.write_text("".join(f"{twos(v, width):0{digits}x}\n" for v in values), encoding="utf-8")


def main():
    text = DATA_H.read_text(encoding="utf-8")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    common_bias = []
    common_mult = []
    common_shift = []
    prelu_mult = []
    prelu_shift = []
    residual_mult = []
    residual_shift = []
    residual_zp = []

    for layer, n_size in LAYERS:
        common_bias.extend(parse_array(text, f"qf_bias_l{layer}")[:n_size])
        common_mult.extend(parse_array(text, f"qf_multiplier_l{layer}")[:n_size])
        common_shift.extend(parse_array(text, f"qf_shift_l{layer}")[:n_size])
        prelu_mult.extend(parse_array(text, f"qf_prelu_multiplier_l{layer}")[:n_size])
        prelu_shift.extend(parse_array(text, f"qf_prelu_shift_l{layer}")[:n_size])
        residual_mult.extend(parse_array(text, f"qf_residual_multiplier_l{layer}")[:n_size])
        residual_shift.extend(parse_array(text, f"qf_residual_shift_l{layer}")[:n_size])
        residual_zp.extend(parse_array(text, f"qf_residual_zero_point_l{layer}")[:n_size])

    write_hex(OUT_DIR / "quant_param_bias.hex", common_bias, 64)
    write_hex(OUT_DIR / "quant_param_requant_mult.hex", common_mult, 32)
    write_hex(OUT_DIR / "quant_param_requant_shift.hex", common_shift, 6)
    write_hex(OUT_DIR / "quant_param_prelu_mult.hex", prelu_mult, 32)
    write_hex(OUT_DIR / "quant_param_prelu_shift.hex", prelu_shift, 6)
    write_hex(OUT_DIR / "quant_param_residual_mult.hex", residual_mult, 32)
    write_hex(OUT_DIR / "quant_param_residual_shift.hex", residual_shift, 6)
    write_hex(OUT_DIR / "quant_param_residual_zero_point.hex", residual_zp, 64)
    print(f"[dump_quant_param_hex] wrote {len(common_bias)} channel entries to {OUT_DIR}")


if __name__ == "__main__":
    main()
