import os
import numpy as np

# Find project root
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))

FIXED_W_DIR = os.path.join(PROJECT_ROOT, "software/golden_weights_fixed")
SIM_DIR = SCRIPT_DIR

# =============================================================================
# Weights: Conv1 (Layer 0) + DW-Conv1 (Layer 1)
# =============================================================================
# Layer 0: conv1_weight.txt — (64, 3, 3, 3) = 1728 int16
with open(os.path.join(FIXED_W_DIR, "conv1_weight.txt"), "r") as f:
    conv1_wgt = [int(line.strip()) for line in f]
# Layer 1: dw_conv1_weight.txt — (64, 1, 3, 3) = 576 int16
with open(os.path.join(FIXED_W_DIR, "dw_conv1_weight.txt"), "r") as f:
    dw1_wgt = [int(line.strip()) for line in f]

all_weights = conv1_wgt + dw1_wgt  # concatenated
w_lines = [f"{(w & 0xFFFF):04x}" for w in all_weights]
with open(os.path.join(SIM_DIR, "weights.hex"), "w") as f:
    f.write("\n".join(w_lines))
print(f"Generated weights.hex ({len(w_lines)} entries: conv1={len(conv1_wgt)}, dw1={len(dw1_wgt)})")

# =============================================================================
# Bias: Conv1 + DW-Conv1
# =============================================================================
with open(os.path.join(FIXED_W_DIR, "conv1_bias.txt"), "r") as f:
    conv1_bias = [int(line.strip()) for line in f]
with open(os.path.join(FIXED_W_DIR, "dw_conv1_bias.txt"), "r") as f:
    dw1_bias = [int(line.strip()) for line in f]

all_biases = conv1_bias + dw1_bias
b_lines = [f"{(b & 0xFFFFFFFF):08x}" for b in all_biases]
with open(os.path.join(SIM_DIR, "bias.hex"), "w") as f:
    f.write("\n".join(b_lines))
print(f"Generated bias.hex ({len(b_lines)} entries: conv1={len(conv1_bias)}, dw1={len(dw1_bias)})")

# =============================================================================
# PReLU: Conv1 + DW-Conv1
# =============================================================================
with open(os.path.join(FIXED_W_DIR, "conv1_prelu.txt"), "r") as f:
    conv1_prelu = [int(line.strip()) for line in f]
with open(os.path.join(FIXED_W_DIR, "dw_conv1_prelu.txt"), "r") as f:
    dw1_prelu = [int(line.strip()) for line in f]

all_prelus = conv1_prelu + dw1_prelu
p_lines = [f"{(p & 0xFFFF):04x}" for p in all_prelus]
with open(os.path.join(SIM_DIR, "prelu.hex"), "w") as f:
    f.write("\n".join(p_lines))
print(f"Generated prelu.hex ({len(p_lines)} entries: conv1={len(conv1_prelu)}, dw1={len(dw1_prelu)})")

# =============================================================================
# Input Image (same as before)
# =============================================================================
with open(os.path.join(PROJECT_ROOT, "software/golden/layer0_in.txt"), "r") as f:
    image_flat = np.array([float(line.strip()) for line in f])

image_chw = image_flat.reshape((3, 112, 96))
image_hwc = image_chw.transpose(1, 2, 0)
image_q10 = np.round(image_hwc.flatten() * 1024).astype(np.int16)

img_lines = [f"{(val & 0xFFFF):04x}" for val in image_q10]
with open(os.path.join(SIM_DIR, "input.hex"), "w") as f:
    f.write("\n".join(img_lines))
print(f"Generated input.hex ({len(img_lines)} entries)")

# =============================================================================
# Config (64-bit)
# Format: {reserved(5), wgt_base(18), is_dw(1), pp(1), prelu(1), stride(2),
#          h(8), w(8), out_ch(10), in_ch(10)}
# =============================================================================
def make_config(in_ch, out_ch, w, h, stride, has_prelu, ping_pong, is_dw, wgt_base):
    val = 0
    val |= (in_ch & 0x3FF)
    val |= (out_ch & 0x3FF) << 10
    val |= (w & 0xFF) << 20
    val |= (h & 0xFF) << 28
    val |= (stride & 0x3) << 36
    val |= (has_prelu & 0x1) << 38
    val |= (ping_pong & 0x1) << 39
    val |= (is_dw & 0x1) << 40
    val |= (wgt_base & 0x3FFFF) << 41
    return val

# Layer 0: Conv1 — stride=2, h=112, w=96, out=64, in=3, prelu=1, pp=0, dw=0, wgt_base=0
config0 = make_config(in_ch=3, out_ch=64, w=96, h=112, stride=2,
                      has_prelu=1, ping_pong=0, is_dw=0, wgt_base=0)

# Layer 1: DW-Conv1 — stride=1, h=56, w=48, out=64, in=64, prelu=1, pp=1, dw=1, wgt_base=1728
config1 = make_config(in_ch=64, out_ch=64, w=48, h=56, stride=1,
                      has_prelu=1, ping_pong=1, is_dw=1, wgt_base=len(conv1_wgt))

with open(os.path.join(SIM_DIR, "config.hex"), "w") as f:
    f.write(f"{config0:016x}\n")
    f.write(f"{config1:016x}\n")
    for _ in range(62):
        f.write("0000000000000000\n")

print(f"Generated config.hex:")
print(f"  Layer 0: Conv1   — h=112, w=96, stride=2, in=3, out=64, wgt_base=0")
print(f"  Layer 1: DW-Conv — h=56, w=48, stride=1, in=64, out=64, wgt_base={len(conv1_wgt)}, is_dw=1, pp=1")
