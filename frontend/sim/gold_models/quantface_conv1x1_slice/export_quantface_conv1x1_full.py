#!/usr/bin/env python3
"""Export full-layer QuantFace-derived hex files for the current top-level RTL.

The JSON config selects the original QuantFace modules.  This script infers
M/K/N from those modules and writes three SRAM images:
  - AO init: first selected layer's quantized input activation
  - WGT init: all selected conv1x1 weights, packed in RTL preload order
  - Golden: final AO SRAM contents expected from the current RTL arithmetic

Important: the expected output models the current RTL postprocess config:
multiplier=1, shift=0, zero_point=0, residual=0, and PReLU multiplier=1.
Therefore the closed-loop test verifies the top/SRAM/preload/array/writeback
path using true QuantFace int8 activations and weights, but it is not yet a
bit-exact MobileFaceNet postprocess golden.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List

import torch


SCRIPT_DIR = Path(__file__).resolve().parent


def resolve_from_script(path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return (SCRIPT_DIR / path).resolve()


def load_json(path: Path) -> Dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, data: object) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def qparams(num_bits: int, x_min, x_max):
    n = 2 ** num_bits - 1
    x_min_t = torch.as_tensor(x_min, dtype=torch.float32)
    x_max_t = torch.as_tensor(x_max, dtype=torch.float32)
    denom = torch.clamp(x_max_t - x_min_t, min=1e-8)
    scale = n / denom
    zero_point = torch.round(scale * x_min_t) + 2 ** (num_bits - 1)
    return scale, zero_point


def quantize_tensor_to_i8(x: torch.Tensor, x_min, x_max, num_bits: int = 8):
    scale, zero_point = qparams(num_bits, x_min, x_max)
    q = torch.round(x * scale - zero_point)
    n = 2 ** (num_bits - 1)
    q = torch.clamp(q, -n, n - 1).to(torch.int16)
    return q, scale, zero_point


def quant_owner(mod):
    return mod.quantAct if hasattr(mod, "quantAct") else mod


def module_by_name(model, name: str):
    modules = dict(model.named_modules())
    if name not in modules:
        raise KeyError("module not found: {}".format(name))
    return modules[name]


def weight_int8_per_out_channel(conv):
    w = conv.weight.detach().cpu()
    flat = w.contiguous().view(conv.out_channels, -1)
    w_min = flat.min(dim=1).values
    w_max = flat.max(dim=1).values
    q, scale, zero_point = quantize_tensor_to_i8(w, w_min, w_max, conv.weight_bit)
    return q, scale, zero_point, w_min, w_max


def clamp_i8_tensor(x: torch.Tensor) -> torch.Tensor:
    return torch.clamp(x, -128, 127).to(torch.int16)


def pack_lanes(vals: List[int], data_w: int) -> int:
    word = 0
    mask = (1 << data_w) - 1
    for lane, value in enumerate(vals):
        word |= (int(value) & mask) << (lane * data_w)
    return word


def write_hex(path: Path, words: List[int], width: int) -> None:
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    with path.open("w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{word & mask:0{digits}x}\n")


def nchw_i8_to_mk(q_nchw: torch.Tensor) -> torch.Tensor:
    # Hardware words are row-major spatial with adjacent channel lanes, which is
    # equivalent to flattening the NCHW tensor as NHWC rows.
    q = q_nchw[0].permute(1, 2, 0).contiguous()
    return q.view(-1, q.shape[-1]).to(torch.int32)


def pack_activation_matrix(mem: List[int], base: int, mat_mk: torch.Tensor,
                           channels: int, lanes: int, data_w: int) -> None:
    tiles = (channels + lanes - 1) // lanes
    m_size = mat_mk.shape[0]
    for m in range(m_size):
        for tile in range(tiles):
            vals = []
            for lane in range(lanes):
                c = tile * lanes + lane
                vals.append(int(mat_mk[m, c]) if c < channels else 0)
            mem[base + m * tiles + tile] = pack_lanes(vals, data_w)


def pack_weight_q_oihw(mem: List[int], base: int, q_oihw: torch.Tensor,
                       k_size: int, n_size: int, lanes: int, data_w: int) -> None:
    # QuantFace conv weight is [out_channel][in_channel][1][1].
    # RTL preload expects [k][packed n].
    n_tiles = (n_size + lanes - 1) // lanes
    for k in range(k_size):
        for tile in range(n_tiles):
            vals = []
            for lane in range(lanes):
                n = tile * lanes + lane
                vals.append(int(q_oihw[n, k, 0, 0]) if n < n_size else 0)
            mem[base + k * n_tiles + tile] = pack_lanes(vals, data_w)


def tensor_summary(x: torch.Tensor) -> Dict:
    return {
        "shape": list(x.shape),
        "min": float(x.min()),
        "max": float(x.max()),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=SCRIPT_DIR / "config.json")
    parser.add_argument("--out-dir", type=Path, default=SCRIPT_DIR / "out")
    parser.add_argument("--prefix", default="quantface_conv1x1_full")
    args = parser.parse_args()

    cfg = load_json(args.config)
    quantface_path = resolve_from_script(cfg["quantface_path"])
    model_path = resolve_from_script(cfg["model_path"])
    sys.path.insert(0, str(quantface_path))

    model = torch.load(model_path, map_location="cpu")
    model.eval()

    watch = set()
    for layer in cfg["layers"]:
        watch.add(layer["conv"])
        watch.add(layer["input_quant"])
        watch.add(layer["output_quant"])
        if layer.get("bn"):
            watch.add(layer["bn"])

    captures = {}
    hooks = []
    for name, mod in model.named_modules():
        if name in watch:
            def make_hook(n):
                def hook(module, inputs, output):
                    captures[n] = {
                        "input": inputs[0].detach().cpu() if inputs else None,
                        "output": output.detach().cpu() if torch.is_tensor(output) else output,
                    }
                return hook
            hooks.append(mod.register_forward_hook(make_hook(name)))

    torch.manual_seed(int(cfg.get("input", {}).get("seed", 392)))
    input_shape = cfg.get("input", {}).get("shape", [1, 3, 112, 112])
    x = torch.randn(*input_shape)
    with torch.no_grad():
        model_out = model(x)

    for hook in hooks:
        hook.remove()

    data_w = int(cfg.get("packing", {}).get("data_w", 8))
    lanes = int(cfg.get("packing", {}).get("lanes", 16))
    word_w = data_w * lanes
    ao_depth = int(cfg.get("packing", {}).get("ao_depth", 65536))
    wgt_depth = int(cfg.get("packing", {}).get("wgt_depth", 65536))
    out_base_default = int(cfg.get("packing", {}).get("out_base", ao_depth // 2))

    ao_mem = [0 for _ in range(ao_depth)]
    wgt_mem = [0 for _ in range(wgt_depth)]
    golden_mem = [0 for _ in range(ao_depth)]

    current_wgt_base = 0
    current_act = None
    exported_layers = []

    for idx, layer in enumerate(cfg["layers"]):
        conv = module_by_name(model, layer["conv"])
        in_quant = module_by_name(model, layer["input_quant"])
        out_quant = module_by_name(model, layer["output_quant"])

        conv_in = captures[layer["conv"]]["input"]
        post_out = captures[layer["output_quant"]]["output"]

        k_size = int(conv.in_channels)
        n_size = int(conv.out_channels)
        h = int(conv_in.shape[2])
        w = int(conv_in.shape[3])
        m_size = h * w

        if idx == 0:
            in_range = quant_owner(in_quant)
            act_q, act_scale, act_zp = quantize_tensor_to_i8(
                conv_in, in_range.x_min.item(), in_range.x_max.item(), 8
            )
            current_act = nchw_i8_to_mk(act_q)
            pack_activation_matrix(ao_mem, 0, current_act, k_size, lanes, data_w)
        elif current_act is None:
            raise RuntimeError("missing previous layer activation")

        if current_act.shape[1] != k_size:
            raise ValueError(
                "layer {} expects K={}, but previous RTL output has K={}".format(
                    layer["name"], k_size, current_act.shape[1]
                )
            )

        w_q, w_scale, w_zp, w_min, w_max = weight_int8_per_out_channel(conv)
        w_mat = w_q[:, :, 0, 0].to(torch.int32).transpose(0, 1).contiguous()

        wgt_base_cfg = layer.get("wgt_base", "auto_after_previous")
        if wgt_base_cfg == "auto_after_previous":
            wgt_base = current_wgt_base
        else:
            wgt_base = int(wgt_base_cfg)
        pack_weight_q_oihw(wgt_mem, wgt_base, w_q, k_size, n_size, lanes, data_w)
        current_wgt_base = wgt_base + k_size * ((n_size + lanes - 1) // lanes)

        acc = current_act.to(torch.int32).matmul(w_mat)
        current_act = clamp_i8_tensor(acc).to(torch.int32)

        out_base = int(layer.get("out_base", out_base_default if idx == 0 else 0))
        if idx == len(cfg["layers"]) - 1:
            pack_activation_matrix(golden_mem, out_base, current_act, n_size, lanes, data_w)

        out_range = quant_owner(out_quant)
        _, post_scale, post_zp = quantize_tensor_to_i8(
            post_out, out_range.x_min.item(), out_range.x_max.item(), 8
        )
        exported_layers.append({
            "name": layer["name"],
            "conv": layer["conv"],
            "bn": layer.get("bn"),
            "input_quant": layer["input_quant"],
            "output_quant": layer["output_quant"],
            "type": layer.get("type", "LY_CONV1X1"),
            "mode": layer.get("mode", "MODE_REQUANT"),
            "m": m_size,
            "k": k_size,
            "n": n_size,
            "act_base": int(layer.get("act_base", 0 if idx == 0 else out_base_default)),
            "wgt_base": wgt_base,
            "out_base": out_base,
            "wgt_words": k_size * ((n_size + lanes - 1) // lanes),
            "conv_input": tensor_summary(conv_in),
            "post_output_quantface": tensor_summary(post_out),
            "post_quantface_quant": {
                "x_min": float(out_range.x_min.item()),
                "x_max": float(out_range.x_max.item()),
                "scale": float(post_scale),
                "zero_point": float(post_zp),
            },
            "weight_quant": {
                "per_out_channel": True,
                "scale_first_16": [float(v) for v in w_scale[:16]],
                "zero_point_first_16": [float(v) for v in w_zp[:16]],
                "min_first_16": [float(v) for v in w_min[:16]],
                "max_first_16": [float(v) for v in w_max[:16]],
            },
        })

    args.out_dir.mkdir(parents=True, exist_ok=True)
    ao_path = args.out_dir / "{}_ao_init.hex".format(args.prefix)
    wgt_path = args.out_dir / "{}_wgt_init.hex".format(args.prefix)
    golden_path = args.out_dir / "{}_golden.hex".format(args.prefix)
    write_hex(ao_path, ao_mem, word_w)
    write_hex(wgt_path, wgt_mem, word_w)
    write_hex(golden_path, golden_mem, word_w)

    meta = {
        "source": {
            "model_path": str(model_path),
            "quantface_path": str(quantface_path),
            "note": "Inputs and weights are from QuantFace backbone.pt. Golden matches current RTL simplified postprocess, not full QuantFace postprocess.",
        },
        "input": {"shape": input_shape, "seed": int(cfg.get("input", {}).get("seed", 392))},
        "packing": {
            "data_w": data_w,
            "lanes": lanes,
            "word_w": word_w,
            "ao_depth": ao_depth,
            "wgt_depth": wgt_depth,
            "out_base": out_base_default,
        },
        "rtl_postprocess_model": {
            "bias": 0,
            "multiplier": 1,
            "shift": 0,
            "zero_point": 0,
            "residual": 0,
            "prelu_multiplier": 1,
            "prelu_shift": 0,
            "formula": "clamp_int8(sum(input_i8 * weight_i8))",
        },
        "model_output": tensor_summary(model_out.detach().cpu()),
        "layers": exported_layers,
        "files": {
            "ao_init": ao_path.name,
            "wgt_init": wgt_path.name,
            "golden": golden_path.name,
        },
    }
    write_json(args.out_dir / "{}_meta.json".format(args.prefix), meta)
    print("Wrote QuantFace-derived full-layer RTL hex to {}".format(args.out_dir))


if __name__ == "__main__":
    main()
