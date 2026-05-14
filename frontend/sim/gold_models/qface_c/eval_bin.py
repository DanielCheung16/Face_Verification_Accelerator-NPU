#!/usr/bin/env python3
"""Evaluate QuantFace and the current HW-spec model on an InsightFace .bin."""

import argparse
import io
import pickle
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from sklearn.model_selection import KFold

import gen_qface_c as gen


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[3]
QFACE_ROOT = REPO_ROOT / "QuantFace"
MODEL_PATH = REPO_ROOT / "pretrained_models" / "quantface_mobilefacenet_w8a8_real" / "backbone.pt"


def load_eval_bin(path, max_pairs=None):
    with Path(path).open("rb") as f:
        bins, issame = pickle.load(f, encoding="bytes")
    if max_pairs is not None:
        bins = bins[: max_pairs * 2]
        issame = issame[:max_pairs]
    return bins, np.asarray(issame, dtype=np.bool_)


def decode_batch(bins):
    imgs = []
    for item in bins:
        raw = bytes(np.asarray(item, dtype=np.uint8).reshape(-1).tolist())
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        arr = np.asarray(img, dtype=np.float32)
        imgs.append(torch.from_numpy(arr).permute(2, 0, 1))
    x = torch.stack(imgs, dim=0)
    return ((x / 255.0) - 0.5) / 0.5


def normalize_rows(x):
    return x / (np.linalg.norm(x, axis=1, keepdims=True) + 1e-12)


def verification_accuracy(embeddings, issame, nfolds=10):
    thresholds = np.arange(0, 4, 0.01)
    emb1 = embeddings[0::2]
    emb2 = embeddings[1::2]
    dist = np.sum(np.square(emb1 - emb2), axis=1)
    folds = KFold(n_splits=nfolds, shuffle=False)
    acc = []
    chosen_thresholds = []
    indices = np.arange(len(issame))
    for train_idx, test_idx in folds.split(indices):
        train_acc = []
        for threshold in thresholds:
            pred = dist[train_idx] < threshold
            train_acc.append(np.mean(pred == issame[train_idx]))
        best_threshold = thresholds[int(np.argmax(train_acc))]
        chosen_thresholds.append(best_threshold)
        pred = dist[test_idx] < best_threshold
        acc.append(np.mean(pred == issame[test_idx]))
    return float(np.mean(acc)), float(np.std(acc)), float(np.mean(chosen_thresholds))


def capture_bn_outputs(model, mods, x):
    hooks = []
    for _, mod in mods.items():
        if mod.__class__.__name__ in ("BatchNorm2d", "BatchNorm1d"):
            def hook(module, inputs, output):
                module._qface_out = output.detach().cpu()
            hooks.append(mod.register_forward_hook(hook))
    with torch.no_grad():
        model(x)
    for hook in hooks:
        hook.remove()


def build_hw_params(model, mods, calib_x):
    capture_bn_outputs(model, mods, calib_x)
    cur_q, cur_scale, cur_zp = gen.quant_asym(calib_x)
    arrays = {"weight": [], "bias": [], "mult": [], "shift": [], "prelu_mult": [], "prelu_shift": []}
    ops = []
    meta = []

    cur_q, cur_scale, cur_zp = gen.conv_bn_prelu_quant(model, mods, "conv1", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    cur_q, cur_scale, cur_zp = gen.conv_bn_prelu_quant(model, mods, "conv2_dw", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    cur_q, cur_scale, cur_zp = gen.depth_wise(model, mods, "conv_23", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False)
    for i in range(4):
        cur_q, cur_scale, cur_zp = gen.depth_wise(model, mods, f"conv_3.model.{i}.0", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=True)
    cur_q, cur_scale, cur_zp = gen.depth_wise(model, mods, "conv_34", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False)
    for i in range(6):
        cur_q, cur_scale, cur_zp = gen.depth_wise(model, mods, f"conv_4.model.{i}.0", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=True)
    cur_q, cur_scale, cur_zp = gen.depth_wise(model, mods, "conv_45", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=False)
    for i in range(2):
        cur_q, cur_scale, cur_zp = gen.depth_wise(model, mods, f"conv_5.model.{i}.0", cur_q, cur_scale, cur_zp, ops, arrays, meta, residual=True)
    cur_q, cur_scale, cur_zp = gen.conv_bn_prelu_quant(model, mods, "conv_6_sep", cur_q, cur_scale, cur_zp, ops, arrays, meta)
    cur_q, cur_scale, cur_zp = gen.linear_block(
        model, mods, "output_layer.conv_6_dw", cur_q, cur_scale, cur_zp, ops, arrays, meta,
        out_range=(mods["output_layer.conv_6_dw.bn"]._qface_out.min().item(),
                   mods["output_layer.conv_6_dw.bn"]._qface_out.max().item()))

    lin = mods["output_layer.linear"]
    bn = mods["output_layer.bn"]
    gamma = bn.weight.detach().cpu().float()
    beta = bn.bias.detach().cpu().float()
    mean = bn.running_mean.detach().cpu().float()
    std = torch.sqrt(bn.running_var.detach().cpu().float() + bn.eps)
    w_fold = lin.weight.detach().cpu().float() * (gamma / std).view(-1, 1)
    b_fold = beta - gamma * mean / std
    wq, ws = gen.quant_sym_linear(w_fold)

    params = {
        "ops": ops,
        "weight": torch.tensor(arrays["weight"], dtype=torch.float32),
        "bias": torch.tensor(arrays["bias"], dtype=torch.int64),
        "mult": torch.tensor(arrays["mult"], dtype=torch.int64),
        "shift": torch.tensor(arrays["shift"], dtype=torch.int64),
        "prelu_mult": torch.tensor(arrays["prelu_mult"], dtype=torch.int64),
        "prelu_shift": torch.tensor(arrays["prelu_shift"], dtype=torch.int64),
        "final_w": wq.to(torch.float64),
        "final_scale": (1.0 / (cur_scale * ws)).to(torch.float64),
        "final_bias": b_fold.to(torch.float64),
    }
    return params


def round_shift(value, shift):
    if shift == 0:
        return value
    return (value + (1 << (shift - 1))) >> shift


def run_hw_batch(x, params):
    cur_q, _, _ = gen.quant_asym(x)
    cur = cur_q.to(torch.int64)
    res = None
    for op in params["ops"]:
        if op["type"] == gen.OP_SAVE_RES:
            res = cur.clone()
            continue
        if op["type"] == gen.OP_RES_ADD:
            main = gen.dequant(cur.to(torch.int32), op["in_scale"], op["in_zero_point"])
            skip = gen.dequant(res.to(torch.int32), op["res_scale"], op["res_zero_point"])
            q = torch.round((main + skip) * op["out_scale"] - op["out_zero_point"])
            cur = q.clamp(-128, 127).to(torch.int64)
            continue

        oc = op["out_c"]
        ic = 1 if op["groups"] == op["in_c"] == op["out_c"] else op["in_c"]
        count = oc * ic * op["kh"] * op["kw"]
        w = params["weight"][op["weight_off"]: op["weight_off"] + count]
        if op["groups"] == op["in_c"] == op["out_c"]:
            w = w.view(oc, 1, op["kh"], op["kw"])
        else:
            w = w.view(oc, ic, op["kh"], op["kw"])
        if op["pad_h"] != 0 or op["pad_w"] != 0:
            cur_in = F.pad(cur, (op["pad_w"], op["pad_w"], op["pad_h"], op["pad_h"]), value=-op["in_zero_point"])
            padding = 0
        else:
            cur_in = cur
            padding = 0
        acc = F.conv2d(cur_in.to(torch.float32), w, None,
                       stride=(op["stride_h"], op["stride_w"]),
                       padding=padding, groups=op["groups"]).to(torch.int64)
        bias = params["bias"][op["bias_off"]: op["bias_off"] + oc].view(1, oc, 1, 1)
        mult = params["mult"][op["param_off"]: op["param_off"] + oc].view(1, oc, 1, 1)
        shift = int(params["shift"][op["param_off"]].item())
        work = (acc << gen.BIAS_SHIFT) + bias
        if op["mode"] == gen.MODE_PRELU:
            prelu_mult = params["prelu_mult"][op["param_off"]: op["param_off"] + oc].view(1, oc, 1, 1)
            prelu_shift = int(params["prelu_shift"][op["param_off"]].item())
            pre = round_shift(work * prelu_mult, prelu_shift)
            work = torch.where(work < 0, pre, work)
        q = round_shift(work * mult, shift + gen.BIAS_SHIFT) + op["out_zero_point_add"]
        cur = q.clamp(-128, 127).to(torch.int64)

    flat = cur.to(torch.float64).view(cur.shape[0], -1)
    emb = flat @ params["final_w"].t()
    emb = emb * params["final_scale"].view(1, -1) + params["final_bias"].view(1, -1)
    return emb.float()


def collect_embeddings(model, params, bins, batch_size, use_flip, run_hw):
    outputs = []
    for flip in ([False, True] if use_flip else [False]):
        embs = []
        for start in range(0, len(bins), batch_size):
            batch = decode_batch(bins[start:start + batch_size])
            if flip:
                batch = torch.flip(batch, dims=[3])
            with torch.no_grad():
                out = run_hw_batch(batch, params) if run_hw else model(batch).detach().cpu()
            embs.append(out.numpy())
            if start % (batch_size * 20) == 0:
                print(f"  {'hw' if run_hw else 'qface'} flip={int(flip)} images={start + len(batch)}/{len(bins)}", flush=True)
        outputs.append(np.concatenate(embs, axis=0))
    emb = sum(outputs)
    return normalize_rows(emb)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default=str(REPO_ROOT / "datasets" / "faces_eval" / "lfw.bin"))
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--max-pairs", type=int, default=None)
    parser.add_argument("--no-flip", action="store_true")
    args = parser.parse_args()

    sys.path.insert(0, str(QFACE_ROOT))
    model = torch.load(MODEL_PATH, map_location="cpu")
    model.eval()
    mods = gen.get_modules(model)

    bins, issame = load_eval_bin(args.bin, args.max_pairs)
    print(f"loaded {Path(args.bin).name}: pairs={len(issame)} images={len(bins)}")
    calib_x = decode_batch(bins[: min(len(bins), args.batch_size)])
    print("building fixed HW params from calibration batch")
    params = build_hw_params(model, mods, calib_x)

    use_flip = not args.no_flip
    print("running QuantFace")
    qface_emb = collect_embeddings(model, params, bins, args.batch_size, use_flip, run_hw=False)
    print("running HW-spec")
    hw_emb = collect_embeddings(model, params, bins, args.batch_size, use_flip, run_hw=True)

    nfolds = 10 if len(issame) >= 10 else 2
    q_acc, q_std, q_th = verification_accuracy(qface_emb, issame, nfolds=nfolds)
    h_acc, h_std, h_th = verification_accuracy(hw_emb, issame, nfolds=nfolds)
    cos = np.sum(qface_emb * hw_emb, axis=1)
    print({
        "pairs": int(len(issame)),
        "flip": bool(use_flip),
        "quantface_acc": q_acc,
        "quantface_std": q_std,
        "quantface_threshold": q_th,
        "hw_spec_acc": h_acc,
        "hw_spec_std": h_std,
        "hw_spec_threshold": h_th,
        "acc_drop": q_acc - h_acc,
        "embedding_cosine_mean": float(np.mean(cos)),
        "embedding_cosine_min": float(np.min(cos)),
    })


if __name__ == "__main__":
    main()
