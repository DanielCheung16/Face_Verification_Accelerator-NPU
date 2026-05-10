#!/usr/bin/env python3
"""Generate C reference data for the current QuantFace conv1x1 slice."""

import json
import sys
from pathlib import Path

import torch


SCRIPT_DIR = Path(__file__).resolve().parent
SLICE_DIR = SCRIPT_DIR.parent / "quantface_conv1x1_slice"
sys.path.insert(0, str(SLICE_DIR))

from export_quantface_conv1x1_hw import (  # noqa: E402
    choose_common_shift,
    load_json,
    module_by_name,
    nchw_q_to_mk,
    qparams,
    quant_owner,
    quantize_asym_i8,
    quantize_sym_i8_per_oc,
    resolve_from_script,
    rtl_round_shift,
)


MODE_REQUANT = 0
MODE_PRELU = 1
MODE_RESIDUAL = 2


def c_array(name, c_type, values, cols=16):
    flat = [int(v) for v in values]
    lines = [f"static const {c_type} {name}[{len(flat)}] = {{"]
    for i in range(0, len(flat), cols):
        chunk = ", ".join(str(v) for v in flat[i:i + cols])
        suffix = "," if i + cols < len(flat) else ""
        lines.append(f"    {chunk}{suffix}")
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def flatten_mat(mat):
    return mat.contiguous().view(-1).tolist()


def mode_value(mode):
    if mode == "MODE_PRELU":
        return MODE_PRELU
    if mode == "MODE_RESIDUAL":
        return MODE_RESIDUAL
    return MODE_REQUANT


def main():
    cfg = load_json(SLICE_DIR / "config.json")
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
    for hook in hooks:
        hook.remove()

    current_act = None
    layers = []
    arrays = []
    true_final = None

    for idx, layer in enumerate(cfg["layers"]):
        conv = module_by_name(model, layer["conv"])
        bn = module_by_name(model, layer["bn"]) if layer.get("bn") else None
        in_qmod = quant_owner(module_by_name(model, layer["input_quant"]))
        out_qmod = quant_owner(module_by_name(model, layer["output_quant"]))
        conv_in = captures[layer["conv"]]["input"]
        post_true = captures[layer["output_quant"]]["output"]

        k_size = int(conv.in_channels)
        n_size = int(conv.out_channels)
        m_size = int(conv_in.shape[2] * conv_in.shape[3])

        residual_mk = None
        residual_scale = None
        residual_zp = None

        if idx == 0:
            act_q, act_scale, act_zp = quantize_asym_i8(conv_in, in_qmod.x_min.item(), in_qmod.x_max.item())
            current_act = nchw_q_to_mk(act_q)
            arrays.append(c_array("qf_input_l0", "int8_t", flatten_mat(current_act)))

            if layer.get("residual_source"):
                residual_float = captures[layer["residual_source"]]["input"]
                res_q, residual_scale, residual_zp = quantize_asym_i8(
                    residual_float, residual_float.min().item(), residual_float.max().item()
                )
                residual_mk = nchw_q_to_mk(res_q)
        else:
            act_scale, act_zp = qparams(8, in_qmod.x_min.item(), in_qmod.x_max.item())

        if residual_mk is None:
            residual_mk = torch.zeros((m_size, n_size), dtype=torch.int32)
        arrays.append(c_array(f"qf_residual_l{idx}", "int8_t", flatten_mat(residual_mk)))

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
        arrays.append(c_array(f"qf_weight_l{idx}", "int8_t", flatten_mat(w_mat)))

        out_scale, out_zp = qparams(8, out_qmod.x_min.item(), out_qmod.x_max.item())
        real_mult = out_scale / (act_scale * w_scale)
        shift = choose_common_shift(real_mult)
        mult = torch.round(real_mult * (2 ** shift)).clamp(-(2**31), 2**31 - 1).to(torch.int64)
        sum_w = w_mat.sum(dim=0).to(torch.float32)
        bias = torch.round(act_zp * sum_w + b_fold * act_scale * w_scale)
        bias = bias.clamp(-(2**31), 2**31 - 1).to(torch.int64)

        prelu_shift = 16
        prelu_mult = torch.ones(n_size, dtype=torch.int64) << prelu_shift
        if layer.get("mode") == "MODE_PRELU":
            prelu_name = layer["output_quant"]
            if prelu_name.endswith(".quantAct"):
                prelu_name = prelu_name[: -len(".quantAct")]
            alpha = module_by_name(model, prelu_name).weight.detach().cpu().float()
            prelu_mult = torch.round(alpha * (2 ** prelu_shift)).clamp(-(2**31), 2**31 - 1).to(torch.int64)

        residual_shift = 0
        residual_mult = torch.zeros(n_size, dtype=torch.int64)
        residual_zp_int = 0
        if layer.get("mode") == "MODE_RESIDUAL" and layer.get("residual_source"):
            residual_real_to_work = out_scale / (residual_scale * real_mult)
            residual_shift = choose_common_shift(residual_real_to_work)
            residual_mult = torch.round(residual_real_to_work * (2 ** residual_shift))
            residual_mult = residual_mult.clamp(-(2**31), 2**31 - 1).to(torch.int64)
            residual_zp_int = int(round(float(residual_zp)))

        arrays.append(c_array(f"qf_bias_l{idx}", "int32_t", bias))
        arrays.append(c_array(f"qf_multiplier_l{idx}", "int32_t", mult))
        arrays.append(c_array(f"qf_shift_l{idx}", "int", [shift] * n_size))
        arrays.append(c_array(f"qf_zero_point_l{idx}", "int32_t", [-int(round(float(out_zp)))] * n_size))
        arrays.append(c_array(f"qf_prelu_multiplier_l{idx}", "int32_t", prelu_mult))
        arrays.append(c_array(f"qf_prelu_shift_l{idx}", "int", [prelu_shift] * n_size))
        arrays.append(c_array(f"qf_residual_multiplier_l{idx}", "int32_t", residual_mult))
        arrays.append(c_array(f"qf_residual_shift_l{idx}", "int", [residual_shift] * n_size))
        arrays.append(c_array(f"qf_residual_zero_point_l{idx}", "int32_t", [residual_zp_int] * n_size))

        acc = current_act.matmul(w_mat)
        if layer.get("mode") == "MODE_RESIDUAL" and layer.get("residual_source"):
            residual_centered = residual_mk.to(torch.int64) + residual_zp_int
            residual_work = rtl_round_shift(
                residual_centered * residual_mult.view(1, -1).to(torch.int64),
                residual_shift,
            )
            acc = acc.to(torch.int64) + residual_work

        work = acc.to(torch.int64) + bias.view(1, -1).to(torch.int64)
        if layer.get("mode") == "MODE_PRELU":
            pre = rtl_round_shift(work * prelu_mult.view(1, -1).to(torch.int64), prelu_shift)
            neg_real = (work < 0) != (mult.view(1, -1).to(torch.int64) < 0)
            work = torch.where(neg_real, pre, work)

        current_act = rtl_round_shift(work * mult.view(1, -1).to(torch.int64), shift)
        current_act = (current_act - int(round(float(out_zp)))).clamp(-128, 127).to(torch.int32)

        if idx == len(cfg["layers"]) - 1:
            arrays.append(c_array(f"qf_expected_l{idx}", "int8_t", flatten_mat(current_act)))
            true_q, _, _ = quantize_asym_i8(post_true, out_qmod.x_min.item(), out_qmod.x_max.item())
            true_final = nchw_q_to_mk(true_q).to(torch.int32)
            arrays.append(c_array(f"qf_true_l{idx}", "int8_t", flatten_mat(true_final)))

        layers.append({
            "name": layer["name"],
            "m": m_size,
            "k": k_size,
            "n": n_size,
            "mode": mode_value(layer.get("mode", "MODE_REQUANT")),
            "shift": int(shift),
            "prelu_shift": int(prelu_shift),
            "residual_shift": int(residual_shift),
            "residual_zero_point": int(residual_zp_int),
        })

    max_m = max(layer["m"] for layer in layers)
    max_ch = max(max(layer["k"], layer["n"]) for layer in layers)

    header = [
        "#ifndef QUANTFACE_CONV1X1_REF_DATA_H",
        "#define QUANTFACE_CONV1X1_REF_DATA_H",
        "",
        "#include <stdint.h>",
        "",
        "#define QF_MODE_REQUANT 0",
        "#define QF_MODE_PRELU 1",
        "#define QF_MODE_RESIDUAL 2",
        f"#define QF_NUM_LAYERS {len(layers)}",
        f"#define QF_MAX_M {max_m}",
        f"#define QF_MAX_CH {max_ch}",
        f"#define QF_L0_M {layers[0]['m']}",
        f"#define QF_L0_K {layers[0]['k']}",
        f"#define QF_L0_N {layers[0]['n']}",
        f"#define QF_L1_M {layers[1]['m']}",
        f"#define QF_L1_K {layers[1]['k']}",
        f"#define QF_L1_N {layers[1]['n']}",
        "",
        "typedef struct {",
        "    int m;",
        "    int k;",
        "    int n;",
        "    int mode;",
        "} qf_layer_cfg_t;",
        "",
        "static const qf_layer_cfg_t qf_layers[QF_NUM_LAYERS] = {",
    ]
    for layer in layers:
        header.append(f"    {{{layer['m']}, {layer['k']}, {layer['n']}, {layer['mode']}}},")
    header += ["};", ""]
    header += arrays
    header += ["#endif", ""]

    (SCRIPT_DIR / "quantface_conv1x1_ref_data.h").write_text("\n".join(header), encoding="utf-8")
    (SCRIPT_DIR / "quantface_conv1x1_ref_meta.json").write_text(json.dumps({"layers": layers}, indent=2) + "\n",
                                                           encoding="utf-8")

    diff = (current_act.float() - true_final.float()).abs()
    print("Wrote quantface_conv1x1_ref_data.h")
    print("Python fixed-point vs QuantFace true quantized:",
          {
              "mae": float(diff.mean()),
              "max_abs": float(diff.max()),
              "mismatch_count": int((diff != 0).sum()),
              "num_values": int(diff.numel()),
          })


if __name__ == "__main__":
    main()
