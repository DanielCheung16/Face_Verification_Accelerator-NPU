import csv
import json
import sys
from pathlib import Path

import torch
import torch.nn as nn


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODEL_PATH = (
    PROJECT_ROOT
    / "pretrained_models"
    / "quantface_mobilefacenet_w8a8_real"
    / "backbone.pt"
)
OUT_DIR = PROJECT_ROOT / "network_parameters" / "mobilefacenet_w8a8_real"

sys.path.insert(0, str(PROJECT_ROOT / "QuantFace"))

from quantization_utils.quant_modules import QuantAct, QuantActPreLu, Quant_Conv2d, Quant_Linear


INTERESTING_TYPES = (
    Quant_Conv2d,
    Quant_Linear,
    QuantActPreLu,
    QuantAct,
    nn.BatchNorm1d,
    nn.BatchNorm2d,
    nn.Linear,
    nn.Conv2d,
)


def shape_of(value):
    if torch.is_tensor(value):
        return list(value.shape)
    if isinstance(value, (tuple, list)):
        return [shape_of(v) for v in value]
    return str(type(value).__name__)


def shape_text(value):
    if isinstance(value, list):
        if value and all(isinstance(v, int) for v in value):
            return "x".join(str(v) for v in value)
        return json.dumps(value)
    if value is None:
        return ""
    return str(value)


def tensor_shape(param):
    if param is None:
        return None
    return list(param.shape)


def own_numel(module):
    return int(sum(p.numel() for p in module.parameters(recurse=False)))


def own_buffer_numel(module):
    return int(sum(b.numel() for b in module.buffers(recurse=False)))


def module_config(module):
    config = {}
    if isinstance(module, (Quant_Conv2d, nn.Conv2d)):
        config.update(
            {
                "in_channels": module.in_channels,
                "out_channels": module.out_channels,
                "kernel_size": list(module.kernel_size),
                "stride": list(module.stride),
                "padding": list(module.padding),
                "dilation": list(module.dilation),
                "groups": module.groups,
                "weight_shape": tensor_shape(module.weight),
                "bias_shape": tensor_shape(module.bias),
            }
        )
        if isinstance(module, Quant_Conv2d):
            config["weight_bit"] = module.weight_bit
            config["full_precision"] = module.full_precision_flag
    elif isinstance(module, (Quant_Linear, nn.Linear)):
        config.update(
            {
                "in_features": module.in_features,
                "out_features": module.out_features,
                "weight_shape": tensor_shape(module.weight),
                "bias_shape": tensor_shape(module.bias),
            }
        )
        if isinstance(module, Quant_Linear):
            config["weight_bit"] = module.weight_bit
            config["full_precision"] = module.full_precision_flag
    elif isinstance(module, (nn.BatchNorm1d, nn.BatchNorm2d)):
        config.update(
            {
                "num_features": module.num_features,
                "eps": module.eps,
                "momentum": module.momentum,
                "affine": module.affine,
                "track_running_stats": module.track_running_stats,
                "weight_shape": tensor_shape(module.weight),
                "bias_shape": tensor_shape(module.bias),
                "running_mean_shape": tensor_shape(module.running_mean),
                "running_var_shape": tensor_shape(module.running_var),
            }
        )
    elif isinstance(module, QuantActPreLu):
        config.update(
            {
                "activation_bit": module.activation_bit,
                "full_precision": module.full_precision_flag,
                "running_stat": module.running_stat,
                "prelu_weight_shape": tensor_shape(module.weight),
            }
        )
        if hasattr(module, "quantAct"):
            config["x_min"] = float(module.quantAct.x_min.item())
            config["x_max"] = float(module.quantAct.x_max.item())
    elif isinstance(module, QuantAct):
        config.update(
            {
                "activation_bit": module.activation_bit,
                "full_precision": module.full_precision_flag,
                "running_stat": module.running_stat,
                "x_min": float(module.x_min.item()),
                "x_max": float(module.x_max.item()),
            }
        )
    return config


def macs_for(module, input_shape, output_shape):
    if not isinstance(input_shape, list) or not isinstance(output_shape, list):
        return None
    if not input_shape or not output_shape:
        return None
    if not all(isinstance(v, int) for v in input_shape + output_shape):
        return None

    if isinstance(module, (Quant_Conv2d, nn.Conv2d)) and len(output_shape) == 4:
        _, out_channels, out_h, out_w = output_shape
        k_h, k_w = module.kernel_size
        kernel_ops = (module.in_channels // module.groups) * k_h * k_w
        return int(output_shape[0] * out_channels * out_h * out_w * kernel_ops)

    if isinstance(module, (Quant_Linear, nn.Linear)) and len(output_shape) == 2:
        return int(output_shape[0] * module.in_features * module.out_features)

    return None


def output_elements(output_shape):
    if not isinstance(output_shape, list) or not all(isinstance(v, int) for v in output_shape):
        return None
    total = 1
    for dim in output_shape:
        total *= dim
    return int(total)


def note_for(name, module):
    if isinstance(module, QuantAct) and ".model." in name and name.endswith(".1"):
        return "residual_add_output_quant"
    if isinstance(module, QuantActPreLu):
        return "prelu_then_activation_quant"
    return ""


def export_tables(model, input_shape):
    rows = []
    hooks = []

    def make_hook(name):
        def hook(module, inputs, output):
            input_shape_value = shape_of(inputs[0]) if inputs else None
            output_shape_value = shape_of(output)
            config = module_config(module)
            row = {
                "index": len(rows),
                "name": name,
                "type": module.__class__.__name__,
                "input_shape": input_shape_value,
                "output_shape": output_shape_value,
                "param_numel": own_numel(module),
                "buffer_numel": own_buffer_numel(module),
                "macs": macs_for(module, input_shape_value, output_shape_value),
                "output_elements": output_elements(output_shape_value),
                "note": note_for(name, module),
            }
            row.update(config)
            rows.append(row)

        return hook

    for name, module in model.named_modules():
        if not name:
            continue
        if name.endswith(".prelu.quantAct"):
            continue
        if isinstance(module, INTERESTING_TYPES):
            hooks.append(module.register_forward_hook(make_hook(name)))

    x = torch.randn(*input_shape)
    with torch.no_grad():
        y = model(x)

    for hook in hooks:
        hook.remove()

    return rows, shape_of(y)


def csv_value(value):
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    if value is None:
        return ""
    return value


def write_csv(rows, path):
    fieldnames = [
        "index",
        "name",
        "type",
        "input_shape",
        "output_shape",
        "in_channels",
        "out_channels",
        "kernel_size",
        "stride",
        "padding",
        "dilation",
        "groups",
        "in_features",
        "out_features",
        "num_features",
        "weight_shape",
        "bias_shape",
        "prelu_weight_shape",
        "running_mean_shape",
        "running_var_shape",
        "param_numel",
        "buffer_numel",
        "macs",
        "output_elements",
        "weight_bit",
        "activation_bit",
        "x_min",
        "x_max",
        "full_precision",
        "running_stat",
        "note",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: csv_value(row.get(key)) for key in fieldnames})


def write_markdown(rows, metadata, path):
    selected = [
        "index",
        "name",
        "type",
        "input_shape",
        "output_shape",
        "kernel_size",
        "stride",
        "padding",
        "groups",
        "param_numel",
        "macs",
        "weight_bit",
        "activation_bit",
        "note",
    ]
    lines = [
        "# MobileFaceNet W8A8 Layer Shape and Parameter Table",
        "",
        f"- Model: `{MODEL_PATH.relative_to(PROJECT_ROOT)}`",
        f"- Input shape: `{shape_text(metadata['input_shape'])}`",
        f"- Output shape: `{shape_text(metadata['output_shape'])}`",
        f"- Total captured layers: `{metadata['captured_layers']}`",
        f"- Captured parameter elements: `{metadata['captured_param_numel']}`",
        f"- Captured MACs: `{metadata['captured_macs']}`",
        "",
        "| " + " | ".join(selected) + " |",
        "| " + " | ".join("---" for _ in selected) + " |",
    ]

    for row in rows:
        values = []
        for key in selected:
            values.append(str(shape_text(row.get(key))).replace("|", "\\|"))
        lines.append("| " + " | ".join(values) + " |")

    path.write_text("\n".join(lines) + "\n")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    model = torch.load(MODEL_PATH, map_location="cpu")
    model.eval()

    input_shape = [1, 3, 112, 112]
    rows, output_shape = export_tables(model, input_shape)
    metadata = {
        "model_path": str(MODEL_PATH),
        "input_shape": input_shape,
        "output_shape": output_shape,
        "captured_layers": len(rows),
        "captured_param_numel": int(sum(row["param_numel"] for row in rows)),
        "captured_buffer_numel": int(sum(row["buffer_numel"] for row in rows)),
        "captured_macs": int(sum(row["macs"] or 0 for row in rows)),
    }

    write_csv(rows, OUT_DIR / "layer_shapes_and_params.csv")
    write_markdown(rows, metadata, OUT_DIR / "layer_shapes_and_params.md")
    (OUT_DIR / "layer_shapes_and_params.json").write_text(
        json.dumps({"metadata": metadata, "layers": rows}, indent=2) + "\n"
    )

    print(f"Wrote {len(rows)} captured layers to {OUT_DIR}")
    print(f"Output shape: {shape_text(output_shape)}")
    print(f"Captured MACs: {metadata['captured_macs']}")


if __name__ == "__main__":
    main()
