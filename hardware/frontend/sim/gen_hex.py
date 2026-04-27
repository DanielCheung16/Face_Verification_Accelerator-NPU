import os
import numpy as np

# Find project root
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))

FIXED_W_DIR = os.path.join(PROJECT_ROOT, "software/golden_weights_fixed")
SIM_DIR = os.path.join(SCRIPT_DIR, "hex")

def load_fixed(filename):
    with open(os.path.join(FIXED_W_DIR, filename), "r") as f:
        return [int(line.strip()) for line in f]

def pack_pw_weights(wgt_raw, out_ch, in_ch):
    wgt_np = np.array(wgt_raw).reshape((out_ch, in_ch))
    packed = []
    for oc in range(out_ch):
        for ic_blk in range(0, in_ch, 9):
            w_slice = wgt_np[oc, ic_blk:ic_blk+9]
            for w in w_slice: packed.append(w)
            for _ in range(9 - len(w_slice)): packed.append(0)
    return packed

# Load all weights
w0 = load_fixed("conv1_weight.txt")
w1 = load_fixed("dw_conv1_weight.txt")
w2 = pack_pw_weights(load_fixed("blocks_0_pw1_weight.txt"), 128, 64)
w3 = load_fixed("blocks_0_dw_weight.txt")
w4 = pack_pw_weights(load_fixed("blocks_0_pw2_weight.txt"), 64, 128)
w5 = pack_pw_weights(load_fixed("blocks_1_pw1_weight.txt"), 128, 64)
w6 = load_fixed("blocks_1_dw_weight.txt")
w7 = pack_pw_weights(load_fixed("blocks_1_pw2_weight.txt"), 64, 128)

all_weights = w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7
with open(os.path.join(SIM_DIR, "weights.hex"), "w") as f:
    for w in all_weights: f.write(f"{(w & 0xFFFF):04x}\n")

# Load all biases
b0 = load_fixed("conv1_bias.txt")
b1 = load_fixed("dw_conv1_bias.txt")
b2 = load_fixed("blocks_0_pw1_bias.txt")
b3 = load_fixed("blocks_0_dw_bias.txt")
b4 = load_fixed("blocks_0_pw2_bias.txt")
b5 = load_fixed("blocks_1_pw1_bias.txt")
b6 = load_fixed("blocks_1_dw_bias.txt")
b7 = load_fixed("blocks_1_pw2_bias.txt")

all_biases = b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7
with open(os.path.join(SIM_DIR, "bias.hex"), "w") as f:
    for b in all_biases: f.write(f"{(b & 0xFFFFFFFF):08x}\n")

# Load all prelus
p0 = load_fixed("conv1_prelu.txt")
p1 = load_fixed("dw_conv1_prelu.txt")
p2 = load_fixed("blocks_0_pw1_prelu.txt")
p3 = load_fixed("blocks_0_dw_prelu.txt")
p4 = [0]*64
p5 = load_fixed("blocks_1_pw1_prelu.txt")
p6 = load_fixed("blocks_1_dw_prelu.txt")
p7 = [0]*64

all_prelus = p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7
with open(os.path.join(SIM_DIR, "prelu.hex"), "w") as f:
    for p in all_prelus: f.write(f"{(p & 0xFFFF):04x}\n")

# Input Image
with open(os.path.join(PROJECT_ROOT, "software/golden/layer0_in.txt"), "r") as f:
    image_flat = np.array([float(line.strip()) for line in f])
image_q10 = np.round(image_flat.reshape((3, 112, 96)).transpose(1, 2, 0).flatten() * 1024).astype(np.int16)
with open(os.path.join(SIM_DIR, "input.hex"), "w") as f:
    for val in image_q10: f.write(f"{(val & 0xFFFF):04x}\n")

# Configs
def make_config(in_ch, out_ch, w, h, stride, has_prelu, is_res, is_pw, is_dw, wgt_base, rd_buf, wr_buf):
    val = 0
    val |= (in_ch & 0x3FF)
    val |= (out_ch & 0x3FF) << 10
    val |= (w & 0xFF) << 20
    val |= (h & 0xFF) << 28
    val |= (stride & 0x3) << 36
    val |= (has_prelu & 0x1) << 38
    val |= (is_res & 0x1) << 39
    val |= (is_pw & 0x1) << 40
    val |= (is_dw & 0x1) << 41
    val |= (wgt_base & 0x3FFFF) << 42
    val |= (rd_buf & 0x3) << 60
    val |= (wr_buf & 0x3) << 62
    return val

c0 = make_config(in_ch=3, out_ch=64, w=96, h=112, stride=2, has_prelu=1, is_res=0, is_pw=0, is_dw=0, wgt_base=0, rd_buf=0, wr_buf=1)
wb1 = len(w0)
c1 = make_config(in_ch=64, out_ch=64, w=48, h=56, stride=1, has_prelu=1, is_res=0, is_pw=0, is_dw=1, wgt_base=wb1, rd_buf=1, wr_buf=2)
wb2 = wb1 + len(w1)
c2 = make_config(in_ch=64, out_ch=128, w=48, h=56, stride=1, has_prelu=1, is_res=0, is_pw=1, is_dw=0, wgt_base=wb2, rd_buf=2, wr_buf=1)
wb3 = wb2 + len(w2)
c3 = make_config(in_ch=128, out_ch=128, w=48, h=56, stride=2, has_prelu=1, is_res=0, is_pw=0, is_dw=1, wgt_base=wb3, rd_buf=1, wr_buf=2)
wb4 = wb3 + len(w3)
c4 = make_config(in_ch=128, out_ch=64, w=24, h=28, stride=1, has_prelu=0, is_res=0, is_pw=1, is_dw=0, wgt_base=wb4, rd_buf=2, wr_buf=1)
wb5 = wb4 + len(w4)
c5 = make_config(in_ch=64, out_ch=128, w=24, h=28, stride=1, has_prelu=1, is_res=0, is_pw=1, is_dw=0, wgt_base=wb5, rd_buf=1, wr_buf=2)
wb6 = wb5 + len(w5)
c6 = make_config(in_ch=128, out_ch=128, w=24, h=28, stride=1, has_prelu=1, is_res=0, is_pw=0, is_dw=1, wgt_base=wb6, rd_buf=2, wr_buf=0) # Write to Buf 0
wb7 = wb6 + len(w6)
c7 = make_config(in_ch=128, out_ch=64, w=24, h=28, stride=1, has_prelu=0, is_res=1, is_pw=1, is_dw=0, wgt_base=wb7, rd_buf=0, wr_buf=2) # Read B0, Add B1, Write B2

all_configs = [c0, c1, c2, c3, c4, c5, c6, c7]
with open(os.path.join(SIM_DIR, "config.hex"), "w") as f:
    for cfg in all_configs: f.write(f"{cfg:016x}\n")
    for _ in range(64 - len(all_configs)): f.write("0000000000000000\n")

print(f"Generated hex files for 8 layers (Layer 0-7) with 0x54000 offsets.")
