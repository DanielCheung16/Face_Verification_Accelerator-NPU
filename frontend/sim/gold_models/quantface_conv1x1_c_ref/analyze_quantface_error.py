#!/usr/bin/env python3
"""Break down the gap between the HW-spec reference and QuantFace."""

import sys
from pathlib import Path

import torch
import torch.nn.functional as F


SCRIPT_DIR = Path(__file__).resolve().parent
SLICE_DIR = SCRIPT_DIR.parent / "quantface_conv1x1_slice"
sys.path.insert(0, str(SLICE_DIR))

from export_quantface_conv1x1_hw import (  # noqa: E402
    load_json,
    module_by_name,
    nchw_q_to_mk,
    qparams,
    quant_owner,
    quantize_asym_i8,
    quantize_sym_i8_per_oc,
    resolve_from_script,
)


def quantface_asym_weight_i8(w):
    flat = w.contiguous().view(w.shape[0], -1)
    w_min = flat.min(dim=1).values
    w_max = flat.max(dim=1).values
    scale, zp = qparams(8, w_min, w_max)
    q = torch.round(w * scale.view(-1, 1, 1, 1) - zp.view(-1, 1, 1, 1))
    q = q.clamp(-128, 127)
    dq = (q + zp.view(-1, 1, 1, 1)) / scale.view(-1, 1, 1, 1)
    return q.to(torch.int16), dq.float(), scale.float(), zp.float()


def dequant_asym(q, scale, zp):
    return (q.float() + zp.float()) / scale.float()


def mk_to_nchw(mat, h, w):
    return mat.view(h, w, -1).permute(2, 0, 1).unsqueeze(0).contiguous()


def stats(name, a, b):
    diff = (a.float() - b.float()).abs()
    print(
        f"{name:42s} mae={float(diff.mean()):10.6f} "
        f"max={float(diff.max()):10.6f} mismatch={int((diff != 0).sum())}/{diff.numel()}"
    )


def main():
    cfg = load_json(SLICE_DIR / "config.json")
    sys.path.insert(0, str(resolve_from_script(cfg["quantface_path"])))
    model = torch.load(resolve_from_script(cfg["model_path"]), map_location="cpu")
    model.eval()

    watch = set()
    for layer in cfg["layers"]:
        watch.update([layer["conv"], layer["bn"], layer["input_quant"], layer["output_quant"]])
        if layer.get("residual_source"):
            watch.add(layer["residual_source"])

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

    current_hw_q = None
    current_hw_float = None

    print("Error breakdown. Float rows compare dequantized tensors; int8 rows compare code values.")
    for idx, layer in enumerate(cfg["layers"]):
        conv = module_by_name(model, layer["conv"])
        bn = module_by_name(model, layer["bn"])
        in_qmod = quant_owner(module_by_name(model, layer["input_quant"]))
        out_qmod = quant_owner(module_by_name(model, layer["output_quant"]))
        conv_in_true = captures[layer["conv"]]["input"]
        conv_out_true = captures[layer["conv"]]["output"]
        bn_out_true = captures[layer["bn"]]["output"]
        out_true = captures[layer["output_quant"]]["output"]

        h = int(conv_in_true.shape[2])
        w = int(conv_in_true.shape[3])

        if idx == 0:
            act_q, act_scale, act_zp = quantize_asym_i8(conv_in_true, in_qmod.x_min.item(), in_qmod.x_max.item())
            current_hw_q = act_q
            current_hw_float = dequant_asym(act_q, act_scale, act_zp)
            stats(f"L{idx} input dequant vs QuantFace input", current_hw_float, conv_in_true)
        else:
            stats(f"L{idx} input from HW vs QuantFace input", current_hw_float, conv_in_true)
            act_scale, act_zp = qparams(8, in_qmod.x_min.item(), in_qmod.x_max.item())

        w_sym_q, w_sym_scale = quantize_sym_i8_per_oc(conv.weight.detach().cpu())
        w_sym_dq = w_sym_q.float() / w_sym_scale.view(-1, 1, 1, 1)
        _, w_asym_dq, _, _ = quantface_asym_weight_i8(conv.weight.detach().cpu())

        sym_conv = F.conv2d(current_hw_float, w_sym_dq, conv.bias, conv.stride, conv.padding,
                            conv.dilation, conv.groups)
        asym_conv = F.conv2d(current_hw_float, w_asym_dq, conv.bias, conv.stride, conv.padding,
                             conv.dilation, conv.groups)
        stats(f"L{idx} sym-weight conv vs QuantFace conv", sym_conv, conv_out_true)
        stats(f"L{idx} asym-weight conv vs QuantFace conv", asym_conv, conv_out_true)

        sym_bn = bn(sym_conv)
        asym_bn = bn(asym_conv)
        stats(f"L{idx} sym-weight BN vs QuantFace BN", sym_bn, bn_out_true)
        stats(f"L{idx} asym-weight BN vs QuantFace BN", asym_bn, bn_out_true)

        branch = sym_bn
        if layer.get("mode") == "MODE_RESIDUAL":
            residual_true = captures[layer["residual_source"]]["input"]
            residual_q_dynamic, residual_scale_dynamic, residual_zp_dynamic = quantize_asym_i8(
                residual_true, residual_true.min().item(), residual_true.max().item()
            )
            residual_dynamic_float = dequant_asym(residual_q_dynamic, residual_scale_dynamic, residual_zp_dynamic)
            stats(f"L{idx} residual dynamic dequant vs true", residual_dynamic_float, residual_true)
            branch = branch + residual_dynamic_float
            stats(f"L{idx} sym BN+residual vs pre-output", branch, captures[layer["output_quant"]]["input"])

        if layer.get("mode") == "MODE_PRELU":
            prelu_name = layer["output_quant"]
            if prelu_name.endswith(".quantAct"):
                prelu_name = prelu_name[: -len(".quantAct")]
            prelu_mod = module_by_name(model, prelu_name)
            branch = F.prelu(branch, prelu_mod.weight.detach().cpu())
            stats(f"L{idx} sym BN+PReLU vs pre-output", branch, captures[layer["output_quant"]]["input"])

        out_q, out_scale, out_zp = quantize_asym_i8(branch, out_qmod.x_min.item(), out_qmod.x_max.item())
        true_q, _, _ = quantize_asym_i8(out_true, out_qmod.x_min.item(), out_qmod.x_max.item())
        stats(f"L{idx} output int8 vs QuantFace int8", out_q, true_q)
        current_hw_q = out_q
        current_hw_float = dequant_asym(out_q, out_scale, out_zp)


if __name__ == "__main__":
    main()
