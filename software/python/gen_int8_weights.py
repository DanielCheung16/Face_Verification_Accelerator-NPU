#!/usr/bin/env python3
"""
Run this script in an environment with PyTorch to generate INT8 (Q2.6) weights.

Usage (from software/python/):
    python3 gen_int8_weights.py

Outputs:
    ../golden_weights_fixed8/<layer>_weight.txt   (int8, Q2.6, scale=64)
    ../golden_weights_fixed8/<layer>_bias.txt     (int32, Q4.12, scale=4096)
    ../golden_weights_fixed8/<layer>_prelu.txt    (int8, Q2.6, scale=64)

Requires:
    pip install torch numpy
    068.ckpt at ../src/068.ckpt
"""

import torch
import torch.nn as nn
import numpy as np
import os, sys, math, zipfile

CKPT_PATH = "../src/068.ckpt"
OUT_DIR   = "../golden_weights_fixed8"
F_BITS    = 6
SCALE_W   = 1 << F_BITS        # 64
SCALE_B   = 1 << (2 * F_BITS)  # 4096


# ── Model definition (matches model.py exactly) ─────────────────────────────
class Bottleneck(nn.Module):
    def __init__(self, inp, oup, stride, expansion):
        super().__init__()
        self.connect = (stride == 1 and inp == oup)
        self.conv = nn.Sequential(
            nn.Conv2d(inp, inp * expansion, 1, 1, 0, bias=False),
            nn.BatchNorm2d(inp * expansion),
            nn.PReLU(inp * expansion),
            nn.Conv2d(inp * expansion, inp * expansion, 3, stride, 1, groups=inp * expansion, bias=False),
            nn.BatchNorm2d(inp * expansion),
            nn.PReLU(inp * expansion),
            nn.Conv2d(inp * expansion, oup, 1, 1, 0, bias=False),
            nn.BatchNorm2d(oup),
        )
    def forward(self, x):
        return x + self.conv(x) if self.connect else self.conv(x)


class ConvBlock(nn.Module):
    def __init__(self, inp, oup, k, s, p, dw=False, linear=False):
        super().__init__()
        self.linear = linear
        self.conv = nn.Conv2d(inp, oup, k, s, p, groups=inp if dw else 1, bias=False)
        self.bn   = nn.BatchNorm2d(oup)
        if not linear:
            self.prelu = nn.PReLU(oup)
    def forward(self, x):
        x = self.bn(self.conv(x))
        return x if self.linear else self.prelu(x)


class MobileFacenet(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1    = ConvBlock(3,   64, 3, 2, 1)
        self.dw_conv1 = ConvBlock(64,  64, 3, 1, 1, dw=True)
        setting = [(2,64,5,2),(4,128,1,2),(2,128,6,1),(4,128,1,2),(2,128,2,1)]
        layers, inp = [], 64
        for t, c, n, s in setting:
            for i in range(n):
                layers.append(Bottleneck(inp, c, s if i == 0 else 1, t))
                inp = c
        self.blocks  = nn.Sequential(*layers)
        self.conv2   = ConvBlock(128, 512, 1, 1, 0)
        self.linear7 = ConvBlock(512, 512, (7,6), 1, 0, dw=True, linear=True)
        self.linear1 = ConvBlock(512, 128, 1, 1, 0, linear=True)
        for m in self.modules():
            if isinstance(m, nn.Conv2d):
                n = m.kernel_size[0] * m.kernel_size[1] * m.out_channels
                m.weight.data.normal_(0, math.sqrt(2. / n))
            elif isinstance(m, nn.BatchNorm2d):
                m.weight.data.fill_(1); m.bias.data.zero_()
    def forward(self, x):
        x = self.conv1(x); x = self.dw_conv1(x); x = self.blocks(x)
        x = self.conv2(x); x = self.linear7(x);  x = self.linear1(x)
        return x.view(x.size(0), -1)
# ─────────────────────────────────────────────────────────────────────────────


def to_q8(t):
    return torch.round(t * SCALE_W).clamp(-128, 127).to(torch.int8).numpy().flatten()

def to_q32(t):
    return torch.round(t * SCALE_B).clamp(-2147483648, 2147483647).to(torch.int32).numpy().flatten()

def save(path, arr):
    np.savetxt(path, arr, fmt="%d")

def fuse(conv, bn):
    std = torch.sqrt(bn.running_var + bn.eps)
    t   = bn.weight / std
    w_f = conv.weight * t.view(-1, 1, 1, 1)
    b_c = conv.bias if conv.bias is not None else torch.zeros_like(bn.running_mean)
    b_f = bn.bias + (b_c - bn.running_mean) * t
    return w_f, b_f

def export_convblock(prefix, blk):
    w, b = fuse(blk.conv, blk.bn)
    save(f"{OUT_DIR}/{prefix}_weight.txt", to_q8(w))
    save(f"{OUT_DIR}/{prefix}_bias.txt",   to_q32(b))
    if not blk.linear:
        save(f"{OUT_DIR}/{prefix}_prelu.txt", to_q8(blk.prelu.weight))
    print(f"  {prefix}")

def export_bottleneck(prefix, btn):
    # conv[0]+[1] = PW1 conv+BN, conv[2] = PReLU
    w, b = fuse(btn.conv[0], btn.conv[1])
    save(f"{OUT_DIR}/{prefix}_pw1_weight.txt", to_q8(w))
    save(f"{OUT_DIR}/{prefix}_pw1_bias.txt",   to_q32(b))
    save(f"{OUT_DIR}/{prefix}_pw1_prelu.txt",  to_q8(btn.conv[2].weight))
    print(f"  {prefix}_pw1")

    # conv[3]+[4] = DW conv+BN, conv[5] = PReLU
    w, b = fuse(btn.conv[3], btn.conv[4])
    save(f"{OUT_DIR}/{prefix}_dw_weight.txt", to_q8(w))
    save(f"{OUT_DIR}/{prefix}_dw_bias.txt",   to_q32(b))
    save(f"{OUT_DIR}/{prefix}_dw_prelu.txt",  to_q8(btn.conv[5].weight))
    print(f"  {prefix}_dw")

    # conv[6]+[7] = PW2 conv+BN (linear, no PReLU)
    w, b = fuse(btn.conv[6], btn.conv[7])
    save(f"{OUT_DIR}/{prefix}_pw2_weight.txt", to_q8(w))
    save(f"{OUT_DIR}/{prefix}_pw2_bias.txt",   to_q32(b))
    print(f"  {prefix}_pw2")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    if not os.path.exists(CKPT_PATH):
        print(f"ERROR: {CKPT_PATH} not found"); sys.exit(1)

    print(f"Loading {CKPT_PATH} ...")
    net = MobileFacenet()
    net.eval()
    ckpt = torch.load(CKPT_PATH, map_location="cpu")
    sd   = ckpt.get("net_state_dict", ckpt)
    sd   = {(k[7:] if k.startswith("module.") else k): v for k, v in sd.items()}
    net.load_state_dict(sd)
    print("Model loaded OK.\n")

    print(f"Exporting INT8 (Q2.6, scale={SCALE_W}) weights → {OUT_DIR}/")
    export_convblock("conv1",    net.conv1)
    export_convblock("dw_conv1", net.dw_conv1)
    for i, btn in enumerate(net.blocks):
        export_bottleneck(f"blocks_{i}", btn)
    export_convblock("conv2",   net.conv2)
    export_convblock("linear7", net.linear7)
    export_convblock("linear1", net.linear1)

    n = len(os.listdir(OUT_DIR))
    print(f"\nDone. {n} files written to {OUT_DIR}/")

    zip_path = os.path.join(os.path.dirname(OUT_DIR), "golden_weights_fixed8.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for fname in os.listdir(OUT_DIR):
            zf.write(os.path.join(OUT_DIR, fname), fname)
    print(f"Zipped → {zip_path}")


if __name__ == "__main__":
    main()
