#!/usr/bin/env python3
"""Export a QuantFace MobileFaceNet conv1x1 slice description.

Run from the project root with:
    source qface_env/bin/activate
    python frontend/sim/gold_models/quantface_conv1x1_slice/export_quantface_conv1x1_slice.py

The JSON config is the source of truth for which QuantFace modules form the
current RTL slice.  This script loads pretrained_models/.../backbone.pt, runs a
deterministic input through the real QuantFace graph, and exports:
  - QuantFace quantization metadata for each selected layer
  - Small packed AO/WGT/golden hex files for RTL bring-up

Important: when k_limit/n_limit are smaller than the real layer dimensions, the
packed hex files are channel slices for bring-up. They are not equal to the full
MobileFaceNet output unless the full K/N dimensions are exported and the RTL has
matching BN/residual/postprocess support.
"""

import argparse
import json
import sys
from pathlib import Path

import torch


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parents[4]


def resolve_from_script(path_text):
    path = Path(path_text)
    if path.is_absolute():
        return path
    return (SCRIPT_DIR / path).resolve()


def load_config(path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def qparams(num_bits, x_min, x_max):
    n = 2 ** num_bits - 1
    x_min_t = torch.as_tensor(x_min, dtype=torch.float32)
    x_max_t = torch.as_tensor(x_max, dtype=torch.float32)
    denom = torch.clamp(x_max_t - x_min_t, min=1e-8)
    scale = n / denom
    zero_point = torch.round(scale * x_min_t) + 2 ** (num_bits - 1)
    return scale, zero_point


def quantize_tensor_to_i8(x, x_min, x_max, num_bits=8):
    scale, zero_point = qparams(num_bits, x_min, x_max)
    q = torch.round(x * scale - zero_point)
    n = 2 ** (num_bits - 1)
    q = torch.clamp(q, -n, n - 1).to(torch.int16)
    return q, scale, zero_point


def weight_int8_per_out_channel(conv):
    w = conv.weight.detach().cpu()
    flat = w.contiguous().view(conv.out_channels, -1)
    w_min = flat.min(dim=1).values
    w_max = flat.max(dim=1).values
    q, scale, zero_point = quantize_tensor_to_i8(w, w_min, w_max, conv.weight_bit)
    return q, scale, zero_point, w_min, w_max


def pack_lanes(vals, data_w):
    word = 0
    for lane, value in enumerate(vals):
        word |= (int(value) & ((1 << data_w) - 1)) << (lane * data_w)
    return word


def write_hex(path, words, width):
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    with path.open("w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{word & mask:0{digits}x}\n")


def pack_activation_nchw_first_m(mem, base, q_nchw, m_limit, channels, lanes, data_w):
    # q_nchw shape: [1, C, H, W]. Hardware packing is row-major spatial with
    # adjacent channel lanes, equivalent to NHWC words.
    q = q_nchw[0].cpu()
    c_total, h, w = q.shape
    tiles = (channels + lanes - 1) // lanes
    for m in range(m_limit):
        y = m // w
        x = m % w
        for tile in range(tiles):
            vals = []
            for lane in range(lanes):
                c = tile * lanes + lane
                vals.append(int(q[c, y, x]) if c < channels and c < c_total and y < h else 0)
            mem[base + m * tiles + tile] = pack_lanes(vals, data_w)


def pack_weight_q_oihw(mem, base, q_oihw, k_limit, n_limit, lanes, data_w):
    # QuantFace conv weight is [out_channel][in_channel][1][1].
    # RTL preload expects [k][packed n].
    n_tiles = (n_limit + lanes - 1) // lanes
    for k in range(k_limit):
        for tile in range(n_tiles):
            vals = []
            for lane in range(lanes):
                n = tile * lanes + lane
                vals.append(int(q_oihw[n, k, 0, 0]) if n < n_limit else 0)
            mem[base + k * n_tiles + tile] = pack_lanes(vals, data_w)


def module_by_name(model, name):
    modules = dict(model.named_modules())
    if name not in modules:
        raise KeyError("module not found: {}".format(name))
    return modules[name]


def tensor_summary(x):
    return {
        "shape": list(x.shape),
        "min": float(x.min()),
        "max": float(x.max()),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=SCRIPT_DIR / "config.json")
    parser.add_argument("--out-dir", type=Path, default=SCRIPT_DIR / "out")
    parser.add_argument("--prefix", default="quantface_conv1x1_slice")
    args = parser.parse_args()

    cfg = load_config(args.config)
    quantface_path = resolve_from_script(cfg["quantface_path"])
    model_path = resolve_from_script(cfg["model_path"])
    sys.path.insert(0, str(quantface_path))

    model = torch.load(model_path, map_location="cpu")
    model.eval()

    captures = {}
    hooks = []
    watch = set()
    for layer in cfg["layers"]:
        watch.add(layer["conv"])
        watch.add(layer["output_quant"])
        watch.add(layer["input_quant"])
        if layer.get("bn"):
            watch.add(layer["bn"])

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

    torch.manual_seed(int(cfg["input"]["seed"]))
    x = torch.randn(*cfg["input"]["shape"])
    with torch.no_grad():
        model_out = model(x)

    for hook in hooks:
        hook.remove()

    data_w = int(cfg["packing"]["data_w"])
    lanes = int(cfg["packing"]["lanes"])
    word_w = data_w * lanes
    ao_depth = int(cfg["packing"]["ao_depth"])
    wgt_depth = int(cfg["packing"]["wgt_depth"])
    out_base = int(cfg["packing"]["out_base"])
    m_limit = int(cfg["slice"]["m_limit"])
    k_limit = int(cfg["slice"]["k_limit"])
    n_limit = int(cfg["slice"]["n_limit"])

    ao_mem = [0 for _ in range(ao_depth)]
    wgt_mem = [0 for _ in range(wgt_depth)]
    golden_mem = [0 for _ in range(ao_depth)]
    exported_layers = []

    current_wgt_base = 0
    final_q = None
    for idx, layer in enumerate(cfg["layers"]):
        conv = module_by_name(model, layer["conv"])
        in_quant = module_by_name(model, layer["input_quant"])
        out_quant = module_by_name(model, layer["output_quant"])

        conv_in = captures[layer["conv"]]["input"]
        conv_out = captures[layer["conv"]]["output"]
        post_out = captures[layer["output_quant"]]["output"]

        in_range_owner = in_quant.quantAct if hasattr(in_quant, "quantAct") else in_quant
        out_range_owner = out_quant.quantAct if hasattr(out_quant, "quantAct") else out_quant

        act_q, act_scale, act_zp = quantize_tensor_to_i8(
            conv_in, in_range_owner.x_min.item(), in_range_owner.x_max.item(), 8
        )
        post_q, post_scale, post_zp = quantize_tensor_to_i8(
            post_out, out_range_owner.x_min.item(), out_range_owner.x_max.item(), 8
        )
        w_q, w_scale, w_zp, w_min, w_max = weight_int8_per_out_channel(conv)

        if layer["wgt_base"] == "auto_after_previous":
            wgt_base = current_wgt_base
        else:
            wgt_base = int(layer["wgt_base"])
        pack_weight_q_oihw(wgt_mem, wgt_base, w_q, k_limit if idx == 0 else n_limit,
                           n_limit, lanes, data_w)
        current_wgt_base = wgt_base + (k_limit if idx == 0 else n_limit) * ((n_limit + lanes - 1) // lanes)

        if idx == 0:
            pack_activation_nchw_first_m(ao_mem, 0, act_q, m_limit, k_limit, lanes, data_w)
        final_q = post_q

        exported_layers.append({
            "name": layer["name"],
            "conv": layer["conv"],
            "bn": layer.get("bn"),
            "input_quant": layer["input_quant"],
            "output_quant": layer["output_quant"],
            "type": layer["type"],
            "mode": layer["mode"],
            "wgt_base": wgt_base,
            "conv_input": tensor_summary(conv_in),
            "conv_output_float_dequant": tensor_summary(conv_out),
            "post_output_float_dequant": tensor_summary(post_out),
            "activation_quant": {
                "x_min": float(in_range_owner.x_min.item()),
                "x_max": float(in_range_owner.x_max.item()),
                "scale": float(act_scale),
                "zero_point": float(act_zp),
            },
            "post_quant": {
                "x_min": float(out_range_owner.x_min.item()),
                "x_max": float(out_range_owner.x_max.item()),
                "scale": float(post_scale),
                "zero_point": float(post_zp),
            },
            "weight_quant": {
                "per_out_channel": True,
                "min_first_n": [float(v) for v in w_min[:n_limit]],
                "max_first_n": [float(v) for v in w_max[:n_limit]],
                "scale_first_n": [float(v) for v in w_scale[:n_limit]],
                "zero_point_first_n": [float(v) for v in w_zp[:n_limit]],
            },
        })

    if final_q is not None:
        pack_activation_nchw_first_m(golden_mem, out_base, final_q, m_limit, n_limit, lanes, data_w)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_hex(args.out_dir / "{}_ao_init.hex".format(args.prefix), ao_mem, word_w)
    write_hex(args.out_dir / "{}_wgt_init.hex".format(args.prefix), wgt_mem, word_w)
    write_hex(args.out_dir / "{}_golden.hex".format(args.prefix), golden_mem, word_w)

    meta = {
        "source": {
            "model_path": str(model_path),
            "quantface_path": str(quantface_path),
            "note": "Generated from QuantFace backbone.pt, not from software/ golden txt files.",
        },
        "input": cfg["input"],
        "packing": cfg["packing"],
        "slice": cfg["slice"],
        "model_output": tensor_summary(model_out.detach().cpu()),
        "layers": exported_layers,
        "files": {
            "ao_init": "{}_ao_init.hex".format(args.prefix),
            "wgt_init": "{}_wgt_init.hex".format(args.prefix),
            "golden": "{}_golden.hex".format(args.prefix),
        },
    }
    with (args.out_dir / "{}_meta.json".format(args.prefix)).open("w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")

    print("Wrote QuantFace conv1x1 slice to {}".format(args.out_dir))


if __name__ == "__main__":
    main()
