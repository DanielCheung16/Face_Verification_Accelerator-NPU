#!/usr/bin/env python3
"""Export hardware-friendly QuantFace conv1x1 closed-loop assets.

Numerical spec:
  weight: per-output-channel symmetric int8
  activation: per-layer asymmetric int8
  acc: int32
  bias: activation zero-point correction + BN folding approximation
  PReLU: per-channel multiplier, common shift
  Requant: per-layer common shift, per-channel multiplier

The generated RTL package is a test config source for the current two-layer
closed-loop path. It is intentionally small and can later become a generated
ROM/config-RAM image.
"""

import argparse
import json
import math
import sys
from pathlib import Path

import torch


SCRIPT_DIR = Path(__file__).resolve().parent
BIAS_SHIFT = 16
REPO_ROOT = SCRIPT_DIR.parents[3]
RTL_SRC = REPO_ROOT / "frontend" / "rtl" / "src"


def resolve_from_script(text):
    path = Path(text)
    return path if path.is_absolute() else (SCRIPT_DIR / path).resolve()


def load_json(path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def qparams(num_bits, x_min, x_max):
    n = 2 ** num_bits - 1
    x_min_t = torch.as_tensor(x_min, dtype=torch.float32)
    x_max_t = torch.as_tensor(x_max, dtype=torch.float32)
    scale = n / torch.clamp(x_max_t - x_min_t, min=1e-8)
    zero_point = torch.round(scale * x_min_t) + 2 ** (num_bits - 1)
    return scale, zero_point


def quantize_asym_i8(x, x_min, x_max):
    scale, zp = qparams(8, x_min, x_max)
    q = torch.round(x * scale - zp).clamp(-128, 127).to(torch.int16)
    return q, scale.float(), zp.float()


def quantize_sym_i8_per_oc(w):
    flat = w.contiguous().view(w.shape[0], -1)
    max_abs = torch.clamp(flat.abs().max(dim=1).values, min=1e-8)
    scale = 127.0 / max_abs
    q = torch.round(w * scale.view(-1, 1, 1, 1)).clamp(-127, 127).to(torch.int16)
    return q, scale.float()


def dequant_asym(q, scale, zp):
    return (q.float() + zp.float()) / scale.float()


def quant_owner(mod):
    return mod.quantAct if hasattr(mod, "quantAct") else mod


def module_by_name(model, name):
    return dict(model.named_modules())[name]


def pack_lanes(vals, data_w):
    word = 0
    mask = (1 << data_w) - 1
    for lane, value in enumerate(vals):
        word |= (int(value) & mask) << (lane * data_w)
    return word


def write_hex(path, words, width):
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    with path.open("w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{word & mask:0{digits}x}\n")


def write_json(path, obj):
    with path.open("w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def nchw_q_to_mk(q):
    q = q[0].permute(1, 2, 0).contiguous()
    return q.view(-1, q.shape[-1]).to(torch.int32)


def pack_activation(mem, base, mat, channels, lanes, data_w):
    tiles = (channels + lanes - 1) // lanes
    for m in range(mat.shape[0]):
        for tile in range(tiles):
            vals = []
            for lane in range(lanes):
                c = tile * lanes + lane
                vals.append(int(mat[m, c]) if c < channels else 0)
            mem[base + m * tiles + tile] = pack_lanes(vals, data_w)


def pack_weight(mem, base, q_oihw, k_size, n_size, lanes, data_w):
    n_tiles = (n_size + lanes - 1) // lanes
    for k in range(k_size):
        for tile in range(n_tiles):
            vals = []
            for lane in range(lanes):
                n = tile * lanes + lane
                vals.append(int(q_oihw[n, k, 0, 0]) if n < n_size else 0)
            mem[base + k * n_tiles + tile] = pack_lanes(vals, data_w)


def choose_common_shift(scales):
    max_abs = max(abs(float(v)) for v in scales if abs(float(v)) > 0.0)
    shift = min(30, int(math.floor(math.log2((2**31 - 1) / max_abs)))) if max_abs > 0 else 24
    return max(0, shift)


def rtl_round_shift(value, shift):
    if shift == 0:
        return value
    return (value + (1 << (shift - 1))) >> shift


def sv_case_function(name, width_decl, default, layers, values):
    lines = [
        "    function automatic {} {};".format(width_decl, name),
        "        input int layer;",
        "        input int ch;",
        "        begin",
        "            {} = {};".format(name, default),
        "            case (layer)",
    ]
    for li, n_ch in enumerate(layers):
        lines.append("                {}: begin".format(li))
        lines.append("                    case (ch)")
        for ch in range(n_ch):
            lines.append("                        {}: {} = {};".format(ch, name, values[li][ch]))
        lines.append("                        default: ;")
        lines.append("                    endcase")
        lines.append("                end")
    lines += ["                default: ;", "            endcase", "        end", "    endfunction", ""]
    return "\n".join(lines)


def sv_signed_literal(width, value):
    value = int(value)
    if value < 0:
        return f"-{width}'sd{-value}"
    return f"{width}'sd{value}"


def emit_sv_pkg(path, layer_meta, params):
    layers = [m["n"] for m in layer_meta]
    text = [
        "package quantface_conv1x1_params_pkg;",
        "    function automatic int qf_num_layers();",
        "        qf_num_layers = {};".format(len(layer_meta)),
        "    endfunction",
        "",
    ]
    text.append(sv_case_function("qf_bias", "logic signed [63:0]", "64'sd0", layers, params["bias"]))
    text.append(sv_case_function("qf_multiplier", "logic signed [31:0]", "32'sd1", layers, params["multiplier"]))
    text.append(sv_case_function("qf_shift", "logic [5:0]", "6'd0", layers, params["shift"]))
    text.append(sv_case_function("qf_zero_point", "logic signed [7:0]", "8'sd0", layers, params["zero_point"]))
    text.append(sv_case_function("qf_prelu_multiplier", "logic signed [31:0]", "32'sd1", layers, params["prelu_multiplier"]))
    text.append(sv_case_function("qf_prelu_shift", "logic [5:0]", "6'd0", layers, params["prelu_shift"]))
    text.append(sv_case_function("qf_residual_multiplier", "logic signed [31:0]", "32'sd0", layers, params["residual_multiplier"]))
    text.append(sv_case_function("qf_residual_shift", "logic [5:0]", "6'd0", layers, params["residual_shift"]))
    text.append(sv_case_function("qf_residual_zero_point", "logic signed [31:0]", "32'sd0", layers, params["residual_zero_point"]))
    text.append("endpackage\n")
    path.write_text("\n".join(text), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=SCRIPT_DIR / "config.json")
    parser.add_argument("--out-dir", type=Path, default=SCRIPT_DIR / "out")
    parser.add_argument("--prefix", default="quantface_conv1x1_full")
    args = parser.parse_args()

    cfg = load_json(args.config)
    sys.path.insert(0, str(resolve_from_script(cfg["quantface_path"])))
    model = torch.load(resolve_from_script(cfg["model_path"]), map_location="cpu")
    model.eval()

    watch = set()
    for layer in cfg["layers"]:
        watch.update([layer["conv"], layer["input_quant"], layer["output_quant"]])
        if layer.get("residual_source"):
            watch.add(layer["residual_source"])
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

    torch.manual_seed(int(cfg["input"]["seed"]))
    with torch.no_grad():
        model(torch.randn(*cfg["input"]["shape"]))
    for h in hooks:
        h.remove()

    data_w = int(cfg["packing"]["data_w"])
    lanes = int(cfg["packing"]["lanes"])
    word_w = data_w * lanes
    ao_depth = int(cfg["packing"]["ao_depth"])
    wgt_depth = int(cfg["packing"]["wgt_depth"])
    out_base_default = int(cfg["packing"]["out_base"])
    ao_mem = [0] * ao_depth
    wgt_mem = [0] * wgt_depth
    golden_mem = [0] * ao_depth
    true_mem = [0] * ao_depth

    current_act = None
    current_wgt_base = 0
    layer_meta = []
    params = {k: [] for k in [
        "bias", "multiplier", "shift", "zero_point", "prelu_multiplier", "prelu_shift",
        "residual_multiplier", "residual_shift", "residual_zero_point",
    ]}
    error_report = None

    for idx, layer in enumerate(cfg["layers"]):
        conv = module_by_name(model, layer["conv"])
        bn = module_by_name(model, layer["bn"]) if layer.get("bn") else None
        in_qmod = quant_owner(module_by_name(model, layer["input_quant"]))
        out_qmod = quant_owner(module_by_name(model, layer["output_quant"]))
        conv_in = captures[layer["conv"]]["input"]
        post_true = captures[layer["output_quant"]]["output"]

        k_size = int(conv.in_channels)
        n_size = int(conv.out_channels)
        h = int(conv_in.shape[2])
        w = int(conv_in.shape[3])
        m_size = h * w

        residual_mk = None
        residual_scale = None
        residual_zp = None

        if idx == 0:
            act_q, act_scale, act_zp = quantize_asym_i8(conv_in, in_qmod.x_min.item(), in_qmod.x_max.item())
            current_act = nchw_q_to_mk(act_q)
            pack_activation(ao_mem, int(layer.get("act_base", 0)), current_act, k_size, lanes, data_w)
            if layer.get("residual_source"):
                residual_float = captures[layer["residual_source"]]["input"]
                res_q, residual_scale, residual_zp = quantize_asym_i8(
                    residual_float, residual_float.min().item(), residual_float.max().item()
                )
                residual_mk = nchw_q_to_mk(res_q)
                pack_activation(ao_mem, int(layer["residual_base"]), residual_mk,
                                residual_mk.shape[1], lanes, data_w)
        else:
            act_scale, act_zp = qparams(8, in_qmod.x_min.item(), in_qmod.x_max.item())

        if bn is not None:
            gamma = bn.weight.detach().cpu().float()
            beta = bn.bias.detach().cpu().float()
            mean = bn.running_mean.detach().cpu().float()
            std = torch.sqrt(bn.running_var.detach().cpu().float() + bn.eps)
        else:
            gamma = torch.ones(n_size)
            beta = torch.zeros(n_size)
            mean = torch.zeros(n_size)
            std = torch.ones(n_size)

        w_fold = conv.weight.detach().cpu().float() * (gamma / std).view(-1, 1, 1, 1)
        b_fold = beta - gamma * mean / std
        w_q, w_scale = quantize_sym_i8_per_oc(w_fold)
        w_mat = w_q[:, :, 0, 0].to(torch.int32).transpose(0, 1).contiguous()
        wgt_base = current_wgt_base if layer.get("wgt_base") == "auto_after_previous" else int(layer.get("wgt_base", 0))
        pack_weight(wgt_mem, wgt_base, w_q, k_size, n_size, lanes, data_w)
        current_wgt_base = wgt_base + k_size * ((n_size + lanes - 1) // lanes)

        out_scale, out_zp = qparams(8, out_qmod.x_min.item(), out_qmod.x_max.item())
        real_mult = out_scale / (act_scale * w_scale)
        shift = choose_common_shift(real_mult)
        mult = torch.round(real_mult * (2 ** shift)).clamp(-(2**31), 2**31 - 1).to(torch.int64)
        sum_w = w_mat.sum(dim=0).to(torch.float32)
        bias = torch.round((act_zp * sum_w + b_fold * act_scale * w_scale) * (2 ** BIAS_SHIFT))
        bias = bias.clamp(-(2**63), 2**63 - 1).to(torch.int64)

        prelu_shift = 16
        prelu_mult = torch.ones(n_size, dtype=torch.int64) << prelu_shift
        if layer.get("mode") == "MODE_PRELU":
            prelu_name = layer["output_quant"]
            if prelu_name.endswith(".quantAct"):
                prelu_name = prelu_name[: -len(".quantAct")]
            prelu_mod = module_by_name(model, prelu_name)
            alpha = prelu_mod.weight.detach().cpu().float()
            prelu_mult = torch.round(alpha * (2 ** prelu_shift)).clamp(-(2**31), 2**31 - 1).to(torch.int64)

        residual_shift = 0
        residual_mult = torch.zeros(n_size, dtype=torch.int64)
        residual_zp_int = 0
        if layer.get("mode") == "MODE_RESIDUAL" and residual_mk is not None:
            residual_real_to_work = out_scale / (residual_scale * real_mult)
            residual_shift = choose_common_shift(residual_real_to_work)
            residual_mult = torch.round(residual_real_to_work * (2 ** residual_shift))
            residual_mult = residual_mult.clamp(-(2**31), 2**31 - 1).to(torch.int64)
            residual_zp_int = int(round(float(residual_zp)))

        acc = current_act.matmul(w_mat)
        work = (acc.to(torch.int64) << BIAS_SHIFT) + bias.view(1, -1).to(torch.int64)
        if layer.get("mode") == "MODE_RESIDUAL" and layer.get("residual_source"):
            residual_centered = residual_mk.to(torch.int64) + residual_zp_int
            residual_work = rtl_round_shift(
                residual_centered * residual_mult.view(1, -1).to(torch.int64),
                residual_shift,
            )
            work = work + (residual_work << BIAS_SHIFT)
        if layer.get("mode") == "MODE_PRELU":
            work_pre = rtl_round_shift(work * prelu_mult.view(1, -1).to(torch.int64), prelu_shift)
            work = torch.where(work < 0, work_pre, work)
        q_hw = rtl_round_shift(work * mult.view(1, -1).to(torch.int64), shift + BIAS_SHIFT)
        q_hw = (q_hw - int(round(float(out_zp)))).clamp(-128, 127).to(torch.int32)
        current_act = q_hw

        out_base = int(layer.get("out_base", out_base_default if idx == 0 else 0))
        if idx == len(cfg["layers"]) - 1:
            pack_activation(golden_mem, out_base, current_act, n_size, lanes, data_w)
            true_q, _, _ = quantize_asym_i8(post_true, out_qmod.x_min.item(), out_qmod.x_max.item())
            true_mk = nchw_q_to_mk(true_q)
            pack_activation(true_mem, out_base, true_mk, n_size, lanes, data_w)
            diff = (current_act.float() - true_mk.float()).abs()
            error_report = {
                "mae": float(diff.mean()),
                "max_abs": float(diff.max()),
                "mismatch_count": int((diff != 0).sum()),
                "num_values": int(diff.numel()),
            }

        layer_meta.append({
            "name": layer["name"], "m": m_size, "k": k_size, "n": n_size,
            "wgt_base": wgt_base, "act_base": int(layer.get("act_base", 0 if idx == 0 else out_base_default)),
            "out_base": out_base, "requant_shift": shift, "prelu_shift": prelu_shift,
            "residual_shift": residual_shift,
            "residual_base": int(layer.get("residual_base", 0)),
            "residual_zero_point": residual_zp_int,
            "act_scale": float(act_scale), "act_zero_point": float(act_zp),
            "out_scale": float(out_scale), "out_zero_point": float(out_zp),
        })
        params["bias"].append([sv_signed_literal(64, int(v)) for v in bias])
        params["multiplier"].append([str(int(v)) for v in mult])
        params["shift"].append(["6'd{}".format(shift) for _ in range(n_size)])
        out_zp_int = int(round(float(out_zp)))
        params["zero_point"].append(["-8'sd{}".format(out_zp_int) for _ in range(n_size)])
        params["prelu_multiplier"].append([str(int(v)) for v in prelu_mult])
        params["prelu_shift"].append(["6'd{}".format(prelu_shift) for _ in range(n_size)])
        params["residual_multiplier"].append([str(int(v)) for v in residual_mult])
        params["residual_shift"].append(["6'd{}".format(residual_shift) for _ in range(n_size)])
        params["residual_zero_point"].append([str(int(residual_zp_int)) for _ in range(n_size)])

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_hex(args.out_dir / f"{args.prefix}_ao_init.hex", ao_mem, word_w)
    write_hex(args.out_dir / f"{args.prefix}_wgt_init.hex", wgt_mem, word_w)
    write_hex(args.out_dir / f"{args.prefix}_golden.hex", golden_mem, word_w)
    write_hex(args.out_dir / f"{args.prefix}_true_quantface.hex", true_mem, word_w)
    emit_sv_pkg(RTL_SRC / "quantface_conv1x1_params_pkg.sv", layer_meta, params)
    write_json(args.out_dir / f"{args.prefix}_meta.json", {
        "layers": layer_meta,
        "error_vs_quantface_true_output": error_report,
        "files": {
            "ao_init": f"{args.prefix}_ao_init.hex",
            "wgt_init": f"{args.prefix}_wgt_init.hex",
            "golden": f"{args.prefix}_golden.hex",
            "true_quantface": f"{args.prefix}_true_quantface.hex",
            "rtl_params": str(RTL_SRC / "quantface_conv1x1_params_pkg.sv"),
        },
    })
    print("Wrote HW-friendly QuantFace assets to {}".format(args.out_dir))
    print("Error vs true QuantFace final quantized output:", error_report)


if __name__ == "__main__":
    main()
