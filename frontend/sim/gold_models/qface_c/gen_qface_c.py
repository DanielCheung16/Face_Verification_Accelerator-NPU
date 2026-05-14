#!/usr/bin/env python3
"""Generate data for the qface_c hardware-spec C reference."""

import argparse
import json
import math
import sys
from pathlib import Path

import torch
import torch.nn.functional as F


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[3]
QFACE_ROOT = REPO_ROOT / "QuantFace"
MODEL_PATH = REPO_ROOT / "pretrained_models" / "quantface_mobilefacenet_w8a8_real" / "backbone.pt"

sys.path.insert(0, str(REPO_ROOT / "frontend" / "sim" / "gold_models" / "quantface_conv1x1_slice"))
from export_quantface_conv1x1_hw import choose_common_shift, qparams, rtl_round_shift  # noqa: E402


MODE_REQUANT = 0
MODE_PRELU = 1
OP_CONV = 0
OP_SAVE_RES = 1
OP_RES_ADD = 2
OP_LINEAR = 3
BIAS_SHIFT = 16


def quant_asym(x, x_min=None, x_max=None):
    if x_min is None:
        x_min = x.min().item()
    if x_max is None:
        x_max = x.max().item()
    scale, zp = qparams(8, x_min, x_max)
    q = torch.round(x * scale - zp).clamp(-128, 127).to(torch.int32)
    return q, float(scale), int(round(float(zp)))


def dequant(q, scale, zp):
    return (q.float() + float(zp)) / float(scale)


def quant_sym_per_oc(w):
    flat = w.contiguous().view(w.shape[0], -1)
    max_abs = torch.clamp(flat.abs().max(dim=1).values, min=1e-8)
    scale = 127.0 / max_abs
    q = torch.round(w * scale.view(-1, 1, 1, 1)).clamp(-127, 127).to(torch.int32)
    return q, scale.float()


def quant_sym_linear(w):
    max_abs = torch.clamp(w.abs().max(dim=1).values, min=1e-8)
    scale = 127.0 / max_abs
    q = torch.round(w * scale.view(-1, 1)).clamp(-127, 127).to(torch.int32)
    return q, scale.float()


def round_shift_tensor(value, shift):
    if shift == 0:
        return value
    return (value + (1 << (shift - 1))) >> shift


def c_array(name, c_type, values, cols=16):
    vals = [int(v) if c_type != "float" else float(v) for v in values]
    if not vals:
        vals = [0.0 if c_type == "float" else 0]
    lines = [f"const {c_type} {name}[{len(vals)}] = {{"]
    for i in range(0, len(vals), cols):
        if c_type == "float":
            chunk = ", ".join("0.0f" if float(v) == 0.0 else f"{v:.9g}f" for v in vals[i:i + cols])
        else:
            chunk = ", ".join(str(v) for v in vals[i:i + cols])
        lines.append("    " + chunk + ("," if i + cols < len(vals) else ""))
    lines += ["};", ""]
    return "\n".join(lines)


def nhwc_flat(q_nchw):
    return q_nchw[0].permute(1, 2, 0).contiguous().view(-1).tolist()


def weight_flat(q_oihw, groups):
    if groups == q_oihw.shape[0] == q_oihw.shape[1]:
        return q_oihw[:, 0, :, :].contiguous().view(-1).tolist()
    return q_oihw.contiguous().view(-1).tolist()


def get_modules(model):
    return dict(model.named_modules())


def conv_bn_prelu_quant(model, mods, name, cur_q, cur_scale, cur_zp, ops, arrays, meta,
                        out_range=None, use_prelu=True):
    conv = mods[name + ".conv"]
    bn = mods[name + ".bn"]
    prelu = mods.get(name + ".prelu")
    qact = mods.get(name + ".prelu.quantAct")
    in_float = dequant(cur_q, cur_scale, cur_zp)

    gamma = bn.weight.detach().cpu().float()
    beta = bn.bias.detach().cpu().float()
    mean = bn.running_mean.detach().cpu().float()
    std = torch.sqrt(bn.running_var.detach().cpu().float() + bn.eps)
    w_fold = conv.weight.detach().cpu().float() * (gamma / std).view(-1, 1, 1, 1)
    b_fold = beta - gamma * mean / std

    wq, ws = quant_sym_per_oc(w_fold)
    y_float = F.conv2d(in_float, wq.float() / ws.view(-1, 1, 1, 1), b_fold,
                       conv.stride, conv.padding, conv.dilation, conv.groups)
    mode = MODE_REQUANT
    prelu_mult = torch.ones(conv.out_channels, dtype=torch.int64) << 16
    if use_prelu:
        y_float = F.prelu(y_float, prelu.weight.detach().cpu().float())
        alpha = prelu.weight.detach().cpu().float()
        prelu_mult = torch.round(alpha * (2 ** 16)).to(torch.int64)
        mode = MODE_PRELU

    if out_range is None:
        if qact is not None:
            out_scale, out_zp = qparams(8, qact.x_min.item(), qact.x_max.item())
            out_min, out_max = qact.x_min.item(), qact.x_max.item()
        else:
            out_min, out_max = y_float.min().item(), y_float.max().item()
            out_scale, out_zp = qparams(8, out_min, out_max)
    else:
        out_min, out_max = out_range
        out_scale, out_zp = qparams(8, out_min, out_max)
    out_zp_i = int(round(float(out_zp)))
    real_mult = out_scale / (cur_scale * ws)
    shift = choose_common_shift(real_mult)
    mult = torch.round(real_mult * (2 ** shift)).to(torch.int64)
    sum_w = wq[:, :, :, :].view(wq.shape[0], -1).sum(dim=1).float()
    bias_real_acc = cur_zp * sum_w + b_fold * cur_scale * ws
    bias = torch.round(bias_real_acc * (2 ** BIAS_SHIFT)).to(torch.int64)

    if conv.padding[0] != 0 or conv.padding[1] != 0:
        cur_q_conv = F.pad(cur_q, (conv.padding[1], conv.padding[1], conv.padding[0], conv.padding[0]),
                           value=-cur_zp)
        conv_padding = (0, 0)
    else:
        cur_q_conv = cur_q
        conv_padding = conv.padding
    acc = F.conv2d(cur_q_conv.double(), wq.double(), None, conv.stride, conv_padding,
                   conv.dilation, conv.groups).to(torch.int64)
    acc = (acc << BIAS_SHIFT) + bias.view(1, -1, 1, 1).to(torch.int64)
    if use_prelu:
        pre = round_shift_tensor(acc * prelu_mult.view(1, -1, 1, 1).to(torch.int64), 16)
        acc = torch.where(acc < 0, pre, acc)
    y_q = round_shift_tensor(acc * mult.view(1, -1, 1, 1).to(torch.int64), shift + BIAS_SHIFT)
    y_q = (y_q - out_zp_i).clamp(-128, 127).to(torch.int32)
    add_conv_op(ops, arrays, meta, conv, cur_q.shape, wq, bias, mult, [shift] * conv.out_channels,
                prelu_mult, [16] * conv.out_channels, mode, -out_zp_i,
                cur_scale, cur_zp, float(out_scale), out_zp_i)
    return y_q, float(out_scale), out_zp_i


def linear_block(model, mods, name, cur_q, cur_scale, cur_zp, ops, arrays, meta, out_range=None):
    return conv_bn_prelu_quant(model, mods, name, cur_q, cur_scale, cur_zp, ops, arrays, meta,
                               out_range=out_range, use_prelu=False)


def add_conv_op(ops, arrays, meta, conv, in_shape, wq, bias, mult, shift, prelu_mult, prelu_shift,
                mode, out_zp_add, in_scale, in_zp, out_scale, out_zp):
    _, in_c, in_h, in_w = in_shape
    weight_off = len(arrays["weight"])
    arrays["weight"].extend(weight_flat(wq, conv.groups))
    bias_off = len(arrays["bias"])
    arrays["bias"].extend([int(v) for v in bias])
    param_off = len(arrays["mult"])
    arrays["mult"].extend([int(v) for v in mult])
    arrays["shift"].extend([int(v) for v in shift])
    arrays["prelu_mult"].extend([int(v) for v in prelu_mult])
    arrays["prelu_shift"].extend([int(v) for v in prelu_shift])
    ops.append({
        "type": OP_CONV, "mode": mode, "in_h": in_h, "in_w": in_w, "in_c": in_c,
        "out_c": conv.out_channels, "kh": conv.kernel_size[0], "kw": conv.kernel_size[1],
        "stride_h": conv.stride[0], "stride_w": conv.stride[1],
        "pad_h": conv.padding[0], "pad_w": conv.padding[1], "groups": conv.groups,
        "weight_off": weight_off, "bias_off": bias_off, "param_off": param_off,
        "out_zero_point_add": out_zp_add, "in_scale": in_scale, "in_zero_point": in_zp,
        "out_scale": out_scale, "out_zero_point": out_zp, "res_scale": 0, "res_zero_point": 0,
    })
    meta.append({"kind": "conv", "out_c": conv.out_channels, "kh": conv.kernel_size[0],
                 "kw": conv.kernel_size[1], "groups": conv.groups})


def add_residual_op(ops, cur_shape, main_scale, main_zp, res_scale, res_zp, out_scale, out_zp):
    _, c, h, w = cur_shape
    ops.append({
        "type": OP_RES_ADD, "mode": MODE_REQUANT, "in_h": h, "in_w": w, "in_c": c,
        "out_c": c, "kh": 1, "kw": 1, "stride_h": 1, "stride_w": 1, "pad_h": 0, "pad_w": 0,
        "groups": c, "weight_off": 0, "bias_off": 0, "param_off": 0, "out_zero_point_add": 0,
        "in_scale": main_scale, "in_zero_point": main_zp,
        "out_scale": out_scale, "out_zero_point": out_zp,
        "res_scale": res_scale, "res_zero_point": res_zp,
    })


def save_res_op(ops, cur_shape):
    _, c, h, w = cur_shape
    ops.append({
        "type": OP_SAVE_RES, "mode": MODE_REQUANT, "in_h": h, "in_w": w, "in_c": c,
        "out_c": c, "kh": 1, "kw": 1, "stride_h": 1, "stride_w": 1, "pad_h": 0, "pad_w": 0,
        "groups": c, "weight_off": 0, "bias_off": 0, "param_off": 0, "out_zero_point_add": 0,
        "in_scale": 0, "in_zero_point": 0, "out_scale": 0, "out_zero_point": 0,
        "res_scale": 0, "res_zero_point": 0,
    })


def depth_wise(model, mods, prefix, cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False):
    res_q, res_scale, res_zp = cur_q, cur_scale, cur_zp
    if residual:
        save_res_op(ops, cur_q.shape)
    cur_q, cur_scale, cur_zp = conv_bn_prelu_quant(model, mods, prefix + ".conv", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    cur_q, cur_scale, cur_zp = conv_bn_prelu_quant(model, mods, prefix + ".conv_dw", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    proj_out = mods[prefix + ".project.bn"]._qface_out
    cur_q, cur_scale, cur_zp = linear_block(model, mods, prefix + ".project", cur_q, cur_scale, cur_zp,
                                            ops, arrays, meta,
                                            out_range=(proj_out.min().item(), proj_out.max().item()))
    if residual:
        qact = mods[prefix.rsplit(".", 1)[0] + ".1"] if prefix.endswith(".0") else None
        if qact is None:
            # For paths like conv_3.model.0.0, the paired quant op is conv_3.model.0.1.
            p = prefix.split(".")
            qname = ".".join(p[:-1] + ["1"])
            qact = mods[qname]
        out_scale_t, out_zp_t = qparams(8, qact.x_min.item(), qact.x_max.item())
        add_residual_op(ops, cur_q.shape, cur_scale, cur_zp, res_scale, res_zp,
                        float(out_scale_t), int(round(float(out_zp_t))))
        out_float = dequant(cur_q, cur_scale, cur_zp) + dequant(res_q, res_scale, res_zp)
        cur_q = torch.round(out_float * out_scale_t - out_zp_t).clamp(-128, 127).to(torch.int32)
        cur_scale, cur_zp = float(out_scale_t), int(round(float(out_zp_t)))
    return cur_q, cur_scale, cur_zp


def c_decl(name, c_type, values):
    return f"extern const {c_type} {name}[{max(1, len(values))}];"


def emit_params(header_path, source_path, ops, arrays, input_flat, output_kind,
                true_embedding, true_i8, final_scale, final_bias, max_act,
                input_shape, output_shape, selected_blocks):
    def op_line(op):
        def ff(v):
            return f"{float(v):.9g}f" if float(v) != 0.0 else "0.0f"
        fields = [
            op["type"], op["mode"], op["in_h"], op["in_w"], op["in_c"], op["out_c"],
            op["kh"], op["kw"], op["stride_h"], op["stride_w"], op["pad_h"], op["pad_w"],
            op["groups"], op["weight_off"], op["bias_off"], op["param_off"], op["out_zero_point_add"],
            ff(op["in_scale"]), op["in_zero_point"], ff(op["out_scale"]), op["out_zero_point"],
            ff(op["res_scale"]), op["res_zero_point"],
        ]
        return "    {" + ", ".join(str(x) for x in fields) + "},"

    qf_true_embedding = true_embedding if true_embedding is not None else []
    qf_true_i8 = true_i8 if true_i8 is not None else []
    header = [
        "#ifndef QFACE_PARAMS_H",
        "#define QFACE_PARAMS_H",
        "#include <stdint.h>",
        '#include "qface_model.h"',
        f"#define QF_BIAS_SHIFT {BIAS_SHIFT}",
        f"#define QF_NUM_OPS {len(ops)}",
        f"#define QF_INPUT_SIZE {len(input_flat)}",
        f"#define QF_INPUT_H {input_shape[2]}",
        f"#define QF_INPUT_W {input_shape[3]}",
        f"#define QF_INPUT_C {input_shape[1]}",
        f"#define QF_OUTPUT_H {output_shape[2]}",
        f"#define QF_OUTPUT_W {output_shape[3]}",
        f"#define QF_OUTPUT_C {output_shape[1]}",
        f"#define QF_OUTPUT_KIND {output_kind}",
        f"#define QF_MAX_ACT {max_act}",
        "#define QF_EMBED 128",
        f"#define QF_GOLDEN_I8_SIZE {len(qf_true_i8)}",
        c_decl("qf_ops", "qf_op_t", ops),
        c_decl("qf_input", "int8_t", input_flat),
        c_decl("qf_weight", "int8_t", arrays["weight"]),
        c_decl("qf_bias", "int64_t", arrays["bias"]),
        c_decl("qf_mult", "int32_t", arrays["mult"]),
        c_decl("qf_shift", "int", arrays["shift"]),
        c_decl("qf_prelu_mult", "int32_t", arrays["prelu_mult"]),
        c_decl("qf_prelu_shift", "int", arrays["prelu_shift"]),
        c_decl("qf_final_scale", "float", final_scale),
        c_decl("qf_final_bias", "float", final_bias),
        c_decl("qf_true_embedding", "float", qf_true_embedding),
        c_decl("qf_true_output_i8", "int8_t", qf_true_i8),
        "#endif",
        "",
    ]

    source = [
        '#include "qface_params.h"',
        "",
        "const qf_op_t qf_ops[QF_NUM_OPS] = {",
    ]
    source += [op_line(op) for op in ops]
    source += ["};", ""]
    source.append(c_array("qf_input", "int8_t", input_flat))
    source.append(c_array("qf_weight", "int8_t", arrays["weight"]))
    source.append(c_array("qf_bias", "int64_t", arrays["bias"]))
    source.append(c_array("qf_mult", "int32_t", arrays["mult"]))
    source.append(c_array("qf_shift", "int", arrays["shift"]))
    source.append(c_array("qf_prelu_mult", "int32_t", arrays["prelu_mult"]))
    source.append(c_array("qf_prelu_shift", "int", arrays["prelu_shift"]))
    source.append(c_array("qf_final_scale", "float", final_scale, cols=8))
    source.append(c_array("qf_final_bias", "float", final_bias, cols=8))
    source.append(c_array("qf_true_embedding", "float", qf_true_embedding, cols=8))
    source.append(c_array("qf_true_output_i8", "int8_t", qf_true_i8))

    header_path.write_text("\n".join(header), encoding="utf-8")
    source_path.write_text("\n".join(source), encoding="utf-8")


def block_names():
    names = ["conv1", "conv2_dw", "conv_23"]
    names += [f"conv_3_{i}" for i in range(4)]
    names += ["conv_34"]
    names += [f"conv_4_{i}" for i in range(6)]
    names += ["conv_45"]
    names += [f"conv_5_{i}" for i in range(2)]
    names += ["conv_6_sep", "output_dw", "embedding"]
    return names


def run_block(block, model, mods, cur_q, cur_scale, cur_zp, ops, arrays, meta):
    if block == "conv1":
        return conv_bn_prelu_quant(model, mods, "conv1", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    if block == "conv2_dw":
        return conv_bn_prelu_quant(model, mods, "conv2_dw", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    if block == "conv_23":
        return depth_wise(model, mods, "conv_23", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False)
    if block.startswith("conv_3_"):
        idx = int(block.rsplit("_", 1)[1])
        return depth_wise(model, mods, f"conv_3.model.{idx}.0", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=True)
    if block == "conv_34":
        return depth_wise(model, mods, "conv_34", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False)
    if block.startswith("conv_4_"):
        idx = int(block.rsplit("_", 1)[1])
        return depth_wise(model, mods, f"conv_4.model.{idx}.0", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=True)
    if block == "conv_45":
        return depth_wise(model, mods, "conv_45", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False)
    if block.startswith("conv_5_"):
        idx = int(block.rsplit("_", 1)[1])
        return depth_wise(model, mods, f"conv_5.model.{idx}.0", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=True)
    if block == "conv_6_sep":
        return conv_bn_prelu_quant(model, mods, "conv_6_sep", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    if block == "output_dw":
        return linear_block(model, mods, "output_layer.conv_6_dw", cur_q, cur_scale, cur_zp,
                            ops, arrays, meta,
                            out_range=(mods["output_layer.conv_6_dw.bn"]._qface_out.min().item(),
                                       mods["output_layer.conv_6_dw.bn"]._qface_out.max().item()))
    raise ValueError(f"unknown block {block}")


def add_embedding_op(model, mods, cur_q, cur_scale, cur_zp, arrays, ops):
    lin = mods["output_layer.linear"]
    bn = mods["output_layer.bn"]
    w = lin.weight.detach().cpu().float()
    gamma = bn.weight.detach().cpu().float()
    beta = bn.bias.detach().cpu().float()
    mean = bn.running_mean.detach().cpu().float()
    std = torch.sqrt(bn.running_var.detach().cpu().float() + bn.eps)
    w_fold = w * (gamma / std).view(-1, 1)
    b_fold = beta - gamma * mean / std
    wq, ws = quant_sym_linear(w_fold)
    weight_off = len(arrays["weight"])
    arrays["weight"].extend(wq.contiguous().view(-1).tolist())
    bias_off = len(arrays["bias"])
    arrays["bias"].extend([0] * 128)
    param_off = len(arrays["mult"])
    arrays["mult"].extend([0] * 128)
    arrays["shift"].extend([0] * 128)
    arrays["prelu_mult"].extend([0] * 128)
    arrays["prelu_shift"].extend([0] * 128)
    final_scale = (1.0 / (cur_scale * ws)).tolist()
    final_bias = b_fold.tolist()
    final_float = F.linear(dequant(cur_q, cur_scale, cur_zp).view(1, -1),
                           wq.float() / ws.view(-1, 1), b_fold)[0]
    ops.append({
        "type": OP_LINEAR, "mode": MODE_REQUANT, "in_h": 1, "in_w": 1, "in_c": 512,
        "out_c": 128, "kh": 1, "kw": 1, "stride_h": 1, "stride_w": 1, "pad_h": 0, "pad_w": 0,
        "groups": 1, "weight_off": weight_off, "bias_off": 0, "param_off": 0,
        "out_zero_point_add": 0, "in_scale": 0, "in_zero_point": 0,
        "out_scale": 0, "out_zero_point": 0, "res_scale": 0, "res_zero_point": 0,
    })
    return final_float, final_scale, final_bias


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=str(SCRIPT_DIR / "generated"))
    parser.add_argument("--start-block", default="conv1",
                        help="First block to emit. Use --list-blocks to see valid names.")
    parser.add_argument("--end-block", default="embedding",
                        help="Last block to emit, inclusive.")
    parser.add_argument("--list-blocks", action="store_true")
    args = parser.parse_args()

    blocks = block_names()
    if args.list_blocks:
        for name in blocks:
            print(name)
        return
    if args.start_block not in blocks:
        raise ValueError(f"unknown --start-block {args.start_block}; use --list-blocks")
    if args.end_block not in blocks:
        raise ValueError(f"unknown --end-block {args.end_block}; use --list-blocks")
    start_idx = blocks.index(args.start_block)
    end_idx = blocks.index(args.end_block)
    if start_idx > end_idx:
        raise ValueError("--start-block must not appear after --end-block")

    sys.path.insert(0, str(QFACE_ROOT))
    model = torch.load(MODEL_PATH, map_location="cpu")
    model.eval()
    mods = get_modules(model)

    # Capture true tensors at BN outputs used to calibrate hardware-only quant points.
    hooks = []
    for name, mod in mods.items():
        if mod.__class__.__name__ in ("BatchNorm2d", "BatchNorm1d"):
            def make_hook(m):
                def hook(module, inputs, output):
                    module._qface_out = output.detach().cpu()
                return hook
            hooks.append(mod.register_forward_hook(make_hook(name)))

    torch.manual_seed(392)
    x = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        true_out = model(x).detach().cpu()[0]
    for h in hooks:
        h.remove()

    cur_q, cur_scale, cur_zp = quant_asym(x)
    input_flat = None
    input_shape = None
    output_shape = None
    arrays = {"weight": [], "bias": [], "mult": [], "shift": [], "prelu_mult": [], "prelu_shift": []}
    ops = []
    meta = []
    final_scale = []
    final_bias = []
    final_float = None
    true_i8 = None
    output_kind = "QF_OUTPUT_I8"

    for idx, block in enumerate(blocks):
        selected = start_idx <= idx <= end_idx
        if idx == start_idx:
            input_flat = nhwc_flat(cur_q)
            input_shape = tuple(cur_q.shape)

        if block == "embedding":
            if selected:
                final_float, final_scale, final_bias = add_embedding_op(
                    model, mods, cur_q, cur_scale, cur_zp, arrays, ops)
                output_kind = "QF_OUTPUT_EMBED"
                output_shape = (1, 128, 1, 1)
            break

        if selected:
            cur_q, cur_scale, cur_zp = run_block(block, model, mods, cur_q, cur_scale, cur_zp,
                                                 ops, arrays, meta)
        else:
            scratch_arrays = {"weight": [], "bias": [], "mult": [], "shift": [],
                              "prelu_mult": [], "prelu_shift": []}
            cur_q, cur_scale, cur_zp = run_block(block, model, mods, cur_q, cur_scale, cur_zp,
                                                 [], scratch_arrays, [])

        if idx == end_idx:
            true_i8 = nhwc_flat(cur_q)
            output_shape = tuple(cur_q.shape)
            break

    max_act = 112 * 112 * 512
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    true_embedding = true_out.tolist() if output_kind == "QF_OUTPUT_EMBED" else None
    emit_params(out_dir / "qface_params.h", out_dir / "qface_params.c", ops, arrays, input_flat,
                output_kind, true_embedding, true_i8, final_scale, final_bias, max_act,
                input_shape, output_shape, blocks[start_idx:end_idx + 1])
    (SCRIPT_DIR / "qface_meta.json").write_text(json.dumps({
        "num_ops": len(ops),
        "num_weights": len(arrays["weight"]),
        "num_bias": len(arrays["bias"]),
        "output_kind": "embedding" if output_kind == "QF_OUTPUT_EMBED" else "i8",
        "start_block": args.start_block,
        "end_block": args.end_block,
        "selected_blocks": blocks[start_idx:end_idx + 1],
        "available_blocks": blocks,
        "input_shape_nchw": list(input_shape),
        "output_shape_nchw": list(output_shape),
        "params_h": str(out_dir / "qface_params.h"),
        "params_c": str(out_dir / "qface_params.c"),
        "note": "HW-spec C data. Intermediate activations are int8 per layer.",
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {out_dir / 'qface_params.h'}")
    print(f"Wrote {out_dir / 'qface_params.c'}")
    print(f"ops={len(ops)} weights={len(arrays['weight'])}")
    if output_kind == "QF_OUTPUT_EMBED":
        diff = (final_float - true_out).abs()
        cosine = F.cosine_similarity(final_float.view(1, -1), true_out.view(1, -1)).item()
        print({
            "python_hw_vs_quantface_mae": float(diff.mean()),
            "python_hw_vs_quantface_rmse": float(torch.sqrt(((final_float - true_out) ** 2).mean())),
            "python_hw_vs_quantface_max_abs": float(diff.max()),
            "python_hw_vs_quantface_cosine": float(cosine),
        })
    else:
        print({
            "python_hw_segment": blocks[start_idx:end_idx + 1],
            "golden_i8_values": len(true_i8),
            "output_shape_nchw": list(output_shape),
        })


if __name__ == "__main__":
    main()
