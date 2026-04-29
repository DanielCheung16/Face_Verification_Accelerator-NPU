import os
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))

FIXED_W_DIR = os.path.join(PROJECT_ROOT, "software/golden_weights_fixed")
SIM_DIR = os.path.join(SCRIPT_DIR, "hex")

def load_fixed(filename):
    with open(os.path.join(FIXED_W_DIR, filename), "r") as f:
        return [int(line.strip()) for line in f]

def pack_pw_weights(wgt_raw, out_ch, in_ch):
    """Pack PW weights: for each output channel, group input channels in blocks of 9."""
    wgt_np = np.array(wgt_raw).reshape((out_ch, in_ch))
    packed = []
    for oc in range(out_ch):
        for ic_blk in range(0, in_ch, 9):
            w_slice = wgt_np[oc, ic_blk:ic_blk+9]
            for w in w_slice: packed.append(w)
            for _ in range(9 - len(w_slice)): packed.append(0)
    return packed

def make_config(in_ch, out_ch, w, h, stride, has_prelu, is_res, is_pw, is_dw, wgt_base, rd_buf, wr_buf):
    # New 64-bit layout: {wr_buf(2),rd_buf(2),wgt_base(20),is_dw(1),is_pw(1),is_res(1),
    #                      prelu(1),stride(2),h(7),w(7),out_ch(10),in_ch(10)}
    assert w <= 127, f"w={w} exceeds 7-bit max"
    assert h <= 127, f"h={h} exceeds 7-bit max"
    assert wgt_base <= 0xFFFFF, f"wgt_base={wgt_base} exceeds 20-bit max"
    val = 0
    val |= (in_ch & 0x3FF)
    val |= (out_ch & 0x3FF) << 10
    val |= (w & 0x7F) << 20
    val |= (h & 0x7F) << 27
    val |= (stride & 0x3) << 34
    val |= (has_prelu & 0x1) << 36
    val |= (is_res & 0x1) << 37
    val |= (is_pw & 0x1) << 38
    val |= (is_dw & 0x1) << 39
    val |= (wgt_base & 0xFFFFF) << 40
    val |= (rd_buf & 0x3) << 60
    val |= (wr_buf & 0x3) << 62
    return val

# ============================================================
# Load all weights
# ============================================================
# L0: Conv1 (standard 3x3, 3->64ch, stride 2)
w0 = load_fixed("conv1_weight.txt")          # 3*64*9 = 1728

# L1: DW-Conv1 (3x3 DW, 64ch, stride 1)
w1 = load_fixed("dw_conv1_weight.txt")       # 64*9 = 576

# L2: B0-PW1 (64->128)
w2 = pack_pw_weights(load_fixed("blocks_0_pw1_weight.txt"), 128, 64)

# L3: B0-DW (128ch, stride 2)
w3 = load_fixed("blocks_0_dw_weight.txt")

# L4: B0-PW2 (128->64, no res)
w4 = pack_pw_weights(load_fixed("blocks_0_pw2_weight.txt"), 64, 128)

# L5: B1-PW1 (64->128)
w5 = pack_pw_weights(load_fixed("blocks_1_pw1_weight.txt"), 128, 64)

# L6: B1-DW (128ch)
w6 = load_fixed("blocks_1_dw_weight.txt")

# L7: B1-PW2+Res (128->64)
w7 = pack_pw_weights(load_fixed("blocks_1_pw2_weight.txt"), 64, 128)

# Blocks 2,3,4 (same structure as Block 1: 64->128->64)
w8  = pack_pw_weights(load_fixed("blocks_2_pw1_weight.txt"), 128, 64)
w9  = load_fixed("blocks_2_dw_weight.txt")
w10 = pack_pw_weights(load_fixed("blocks_2_pw2_weight.txt"), 64, 128)

w11 = pack_pw_weights(load_fixed("blocks_3_pw1_weight.txt"), 128, 64)
w12 = load_fixed("blocks_3_dw_weight.txt")
w13 = pack_pw_weights(load_fixed("blocks_3_pw2_weight.txt"), 64, 128)

w14 = pack_pw_weights(load_fixed("blocks_4_pw1_weight.txt"), 128, 64)
w15 = load_fixed("blocks_4_dw_weight.txt")
w16 = pack_pw_weights(load_fixed("blocks_4_pw2_weight.txt"), 64, 128)

# Block 5 (t=4, stride 2, 64->256->128, no res)
w17 = pack_pw_weights(load_fixed("blocks_5_pw1_weight.txt"), 256, 64)
w18 = load_fixed("blocks_5_dw_weight.txt")
w19 = pack_pw_weights(load_fixed("blocks_5_pw2_weight.txt"), 128, 256)

# Blocks 6-11 (t=2, stride 1, 128->256->128, with res)
w20 = pack_pw_weights(load_fixed("blocks_6_pw1_weight.txt"),  256, 128)
w21 = load_fixed("blocks_6_dw_weight.txt")
w22 = pack_pw_weights(load_fixed("blocks_6_pw2_weight.txt"),  128, 256)

w23 = pack_pw_weights(load_fixed("blocks_7_pw1_weight.txt"),  256, 128)
w24 = load_fixed("blocks_7_dw_weight.txt")
w25 = pack_pw_weights(load_fixed("blocks_7_pw2_weight.txt"),  128, 256)

w26 = pack_pw_weights(load_fixed("blocks_8_pw1_weight.txt"),  256, 128)
w27 = load_fixed("blocks_8_dw_weight.txt")
w28 = pack_pw_weights(load_fixed("blocks_8_pw2_weight.txt"),  128, 256)

w29 = pack_pw_weights(load_fixed("blocks_9_pw1_weight.txt"),  256, 128)
w30 = load_fixed("blocks_9_dw_weight.txt")
w31 = pack_pw_weights(load_fixed("blocks_9_pw2_weight.txt"),  128, 256)

w32 = pack_pw_weights(load_fixed("blocks_10_pw1_weight.txt"), 256, 128)
w33 = load_fixed("blocks_10_dw_weight.txt")
w34 = pack_pw_weights(load_fixed("blocks_10_pw2_weight.txt"), 128, 256)

w35 = pack_pw_weights(load_fixed("blocks_11_pw1_weight.txt"), 256, 128)
w36 = load_fixed("blocks_11_dw_weight.txt")
w37 = pack_pw_weights(load_fixed("blocks_11_pw2_weight.txt"), 128, 256)

# Block 12 (t=4, stride 2, 128->512->128, no res)
w38 = pack_pw_weights(load_fixed("blocks_12_pw1_weight.txt"), 512, 128)
w39 = load_fixed("blocks_12_dw_weight.txt")
w40 = pack_pw_weights(load_fixed("blocks_12_pw2_weight.txt"), 128, 512)

# Blocks 13,14 (t=2, stride 1, 128->256->128, with res)
w41 = pack_pw_weights(load_fixed("blocks_13_pw1_weight.txt"), 256, 128)
w42 = load_fixed("blocks_13_dw_weight.txt")
w43 = pack_pw_weights(load_fixed("blocks_13_pw2_weight.txt"), 128, 256)

w44 = pack_pw_weights(load_fixed("blocks_14_pw1_weight.txt"), 256, 128)
w45 = load_fixed("blocks_14_dw_weight.txt")
w46 = pack_pw_weights(load_fixed("blocks_14_pw2_weight.txt"), 128, 256)

# L47: Conv2 (1x1 PW, 128->512)
w47 = pack_pw_weights(load_fixed("conv2_weight.txt"), 512, 128)

all_weights = (w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7 +
               w8 + w9 + w10 + w11 + w12 + w13 + w14 + w15 + w16 +
               w17 + w18 + w19 +
               w20 + w21 + w22 + w23 + w24 + w25 +
               w26 + w27 + w28 + w29 + w30 + w31 +
               w32 + w33 + w34 + w35 + w36 + w37 +
               w38 + w39 + w40 +
               w41 + w42 + w43 + w44 + w45 + w46 +
               w47)
print(f"Total weight entries: {len(all_weights)} (max 20-bit: {2**20})")
assert len(all_weights) < 2**20, "Weight overflow!"
with open(os.path.join(SIM_DIR, "weights.hex"), "w") as f:
    for w in all_weights: f.write(f"{(w & 0xFFFF):04x}\n")

# ============================================================
# Load all biases
# ============================================================
b0  = load_fixed("conv1_bias.txt")
b1  = load_fixed("dw_conv1_bias.txt")
b2  = load_fixed("blocks_0_pw1_bias.txt")
b3  = load_fixed("blocks_0_dw_bias.txt")
b4  = load_fixed("blocks_0_pw2_bias.txt")
b5  = load_fixed("blocks_1_pw1_bias.txt")
b6  = load_fixed("blocks_1_dw_bias.txt")
b7  = load_fixed("blocks_1_pw2_bias.txt")
b8  = load_fixed("blocks_2_pw1_bias.txt")
b9  = load_fixed("blocks_2_dw_bias.txt")
b10 = load_fixed("blocks_2_pw2_bias.txt")
b11 = load_fixed("blocks_3_pw1_bias.txt")
b12 = load_fixed("blocks_3_dw_bias.txt")
b13 = load_fixed("blocks_3_pw2_bias.txt")
b14 = load_fixed("blocks_4_pw1_bias.txt")
b15 = load_fixed("blocks_4_dw_bias.txt")
b16 = load_fixed("blocks_4_pw2_bias.txt")
b17 = load_fixed("blocks_5_pw1_bias.txt")
b18 = load_fixed("blocks_5_dw_bias.txt")
b19 = load_fixed("blocks_5_pw2_bias.txt")
b20 = load_fixed("blocks_6_pw1_bias.txt")
b21 = load_fixed("blocks_6_dw_bias.txt")
b22 = load_fixed("blocks_6_pw2_bias.txt")
b23 = load_fixed("blocks_7_pw1_bias.txt")
b24 = load_fixed("blocks_7_dw_bias.txt")
b25 = load_fixed("blocks_7_pw2_bias.txt")
b26 = load_fixed("blocks_8_pw1_bias.txt")
b27 = load_fixed("blocks_8_dw_bias.txt")
b28 = load_fixed("blocks_8_pw2_bias.txt")
b29 = load_fixed("blocks_9_pw1_bias.txt")
b30 = load_fixed("blocks_9_dw_bias.txt")
b31 = load_fixed("blocks_9_pw2_bias.txt")
b32 = load_fixed("blocks_10_pw1_bias.txt")
b33 = load_fixed("blocks_10_dw_bias.txt")
b34 = load_fixed("blocks_10_pw2_bias.txt")
b35 = load_fixed("blocks_11_pw1_bias.txt")
b36 = load_fixed("blocks_11_dw_bias.txt")
b37 = load_fixed("blocks_11_pw2_bias.txt")
b38 = load_fixed("blocks_12_pw1_bias.txt")
b39 = load_fixed("blocks_12_dw_bias.txt")
b40 = load_fixed("blocks_12_pw2_bias.txt")
b41 = load_fixed("blocks_13_pw1_bias.txt")
b42 = load_fixed("blocks_13_dw_bias.txt")
b43 = load_fixed("blocks_13_pw2_bias.txt")
b44 = load_fixed("blocks_14_pw1_bias.txt")
b45 = load_fixed("blocks_14_dw_bias.txt")
b46 = load_fixed("blocks_14_pw2_bias.txt")
b47 = load_fixed("conv2_bias.txt")

all_biases = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7 +
              b8 + b9 + b10 + b11 + b12 + b13 + b14 + b15 + b16 +
              b17 + b18 + b19 +
              b20 + b21 + b22 + b23 + b24 + b25 +
              b26 + b27 + b28 + b29 + b30 + b31 +
              b32 + b33 + b34 + b35 + b36 + b37 +
              b38 + b39 + b40 +
              b41 + b42 + b43 + b44 + b45 + b46 +
              b47)
print(f"Total bias entries: {len(all_biases)} (max 14-bit: {2**14})")
assert len(all_biases) < 2**14, "Bias overflow!"
with open(os.path.join(SIM_DIR, "bias.hex"), "w") as f:
    for b in all_biases: f.write(f"{(b & 0xFFFFFFFF):08x}\n")

# ============================================================
# Load all PReLUs (layers without PReLU use zeros)
# ============================================================
p0  = load_fixed("conv1_prelu.txt")
p1  = load_fixed("dw_conv1_prelu.txt")
p2  = load_fixed("blocks_0_pw1_prelu.txt")
p3  = load_fixed("blocks_0_dw_prelu.txt")
p4  = [0]*64    # B0-PW2: no prelu
p5  = load_fixed("blocks_1_pw1_prelu.txt")
p6  = load_fixed("blocks_1_dw_prelu.txt")
p7  = [0]*64    # B1-PW2+Res: no prelu
p8  = load_fixed("blocks_2_pw1_prelu.txt")
p9  = load_fixed("blocks_2_dw_prelu.txt")
p10 = [0]*64
p11 = load_fixed("blocks_3_pw1_prelu.txt")
p12 = load_fixed("blocks_3_dw_prelu.txt")
p13 = [0]*64
p14 = load_fixed("blocks_4_pw1_prelu.txt")
p15 = load_fixed("blocks_4_dw_prelu.txt")
p16 = [0]*64
p17 = load_fixed("blocks_5_pw1_prelu.txt")
p18 = load_fixed("blocks_5_dw_prelu.txt")
p19 = [0]*128   # B5-PW2: no prelu, 128ch
p20 = load_fixed("blocks_6_pw1_prelu.txt")
p21 = load_fixed("blocks_6_dw_prelu.txt")
p22 = [0]*128
p23 = load_fixed("blocks_7_pw1_prelu.txt")
p24 = load_fixed("blocks_7_dw_prelu.txt")
p25 = [0]*128
p26 = load_fixed("blocks_8_pw1_prelu.txt")
p27 = load_fixed("blocks_8_dw_prelu.txt")
p28 = [0]*128
p29 = load_fixed("blocks_9_pw1_prelu.txt")
p30 = load_fixed("blocks_9_dw_prelu.txt")
p31 = [0]*128
p32 = load_fixed("blocks_10_pw1_prelu.txt")
p33 = load_fixed("blocks_10_dw_prelu.txt")
p34 = [0]*128
p35 = load_fixed("blocks_11_pw1_prelu.txt")
p36 = load_fixed("blocks_11_dw_prelu.txt")
p37 = [0]*128
p38 = load_fixed("blocks_12_pw1_prelu.txt")
p39 = load_fixed("blocks_12_dw_prelu.txt")
p40 = [0]*128   # B12-PW2: no prelu
p41 = load_fixed("blocks_13_pw1_prelu.txt")
p42 = load_fixed("blocks_13_dw_prelu.txt")
p43 = [0]*128
p44 = load_fixed("blocks_14_pw1_prelu.txt")
p45 = load_fixed("blocks_14_dw_prelu.txt")
p46 = [0]*128
p47 = load_fixed("conv2_prelu.txt")

all_prelus = (p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7 +
              p8 + p9 + p10 + p11 + p12 + p13 + p14 + p15 + p16 +
              p17 + p18 + p19 +
              p20 + p21 + p22 + p23 + p24 + p25 +
              p26 + p27 + p28 + p29 + p30 + p31 +
              p32 + p33 + p34 + p35 + p36 + p37 +
              p38 + p39 + p40 +
              p41 + p42 + p43 + p44 + p45 + p46 +
              p47)
assert len(all_prelus) == len(all_biases), "Bias/PReLU count mismatch!"
with open(os.path.join(SIM_DIR, "prelu.hex"), "w") as f:
    for p in all_prelus: f.write(f"{(p & 0xFFFF):04x}\n")

# ============================================================
# Input Image (Q10)
# ============================================================
with open(os.path.join(PROJECT_ROOT, "software/golden/layer0_in.txt"), "r") as f:
    image_flat = np.array([float(line.strip()) for line in f])
image_q10 = np.round(image_flat.reshape((3, 112, 96)).transpose(1, 2, 0).flatten() * 1024).astype(np.int16)
with open(os.path.join(SIM_DIR, "input.hex"), "w") as f:
    for val in image_q10: f.write(f"{(val & 0xFFFF):04x}\n")

# ============================================================
# Build layer configs with cumulative weight base
# ============================================================
weights_list = [w0,w1,w2,w3,w4,w5,w6,w7,
                w8,w9,w10,w11,w12,w13,w14,w15,w16,
                w17,w18,w19,
                w20,w21,w22,w23,w24,w25,
                w26,w27,w28,w29,w30,w31,
                w32,w33,w34,w35,w36,w37,
                w38,w39,w40,
                w41,w42,w43,w44,w45,w46,
                w47]

# Compute cumulative weight bases
wb = [0]
for wl in weights_list[:-1]:
    wb.append(wb[-1] + len(wl))

# Buffer allocation:
# B0=0x00000, B1=0x54000, B2=0xA8000
# Alternating pattern based on current block output buffer.
# See note.md for detailed derivation.
#
# Layer | rd | wr | Description
#   0   |  0 |  1 | Conv1
#   1   |  1 |  2 | DW1
#   2   |  2 |  1 | B0-PW1
#   3   |  1 |  2 | B0-DW (stride 2)
#   4   |  2 |  1 | B0-PW2 (no res)
#   5   |  1 |  2 | B1-PW1
#   6   |  2 |  0 | B1-DW
#   7   |  0 |  2 | B1-PW2+Res (res=B1)
#   8   |  2 |  1 | B2-PW1  ... (alternating)

configs = [
    # L0: Conv1, 3->64, stride 2, 112x96 -> 56x48
    make_config(3,   64,  96, 112, 2, 1, 0, 0, 0, wb[0],  0, 1),
    # L1: DW1, 64ch, stride 1, 56x48
    make_config(64,  64,  48,  56, 1, 1, 0, 0, 1, wb[1],  1, 2),
    # L2: B0-PW1, 64->128, 56x48
    make_config(64,  128, 48,  56, 1, 1, 0, 1, 0, wb[2],  2, 1),
    # L3: B0-DW, 128ch, stride 2, 56x48 -> 28x24
    make_config(128, 128, 48,  56, 2, 1, 0, 0, 1, wb[3],  1, 2),
    # L4: B0-PW2, 128->64, 28x24, no res
    make_config(128, 64,  24,  28, 1, 0, 0, 1, 0, wb[4],  2, 1),
    # L5: B1-PW1, 64->128, 28x24
    make_config(64,  128, 24,  28, 1, 1, 0, 1, 0, wb[5],  1, 2),
    # L6: B1-DW, 128ch, 28x24, wr->B0
    make_config(128, 128, 24,  28, 1, 1, 0, 0, 1, wb[6],  2, 0),
    # L7: B1-PW2+Res, 128->64, rd=B0, res=B1, wr=B2
    make_config(128, 64,  24,  28, 1, 0, 1, 1, 0, wb[7],  0, 2),
    # L8: B2-PW1, 64->128, rd=B2, wr=B1
    make_config(64,  128, 24,  28, 1, 1, 0, 1, 0, wb[8],  2, 1),
    # L9: B2-DW, 128ch, rd=B1, wr=B0
    make_config(128, 128, 24,  28, 1, 1, 0, 0, 1, wb[9],  1, 0),
    # L10: B2-PW2+Res, 128->64, rd=B0, res=B2, wr=B1
    make_config(128, 64,  24,  28, 1, 0, 1, 1, 0, wb[10], 0, 1),
    # L11: B3-PW1, 64->128, rd=B1, wr=B2
    make_config(64,  128, 24,  28, 1, 1, 0, 1, 0, wb[11], 1, 2),
    # L12: B3-DW, 128ch, rd=B2, wr=B0
    make_config(128, 128, 24,  28, 1, 1, 0, 0, 1, wb[12], 2, 0),
    # L13: B3-PW2+Res, rd=B0, res=B1, wr=B2
    make_config(128, 64,  24,  28, 1, 0, 1, 1, 0, wb[13], 0, 2),
    # L14: B4-PW1, rd=B2, wr=B1
    make_config(64,  128, 24,  28, 1, 1, 0, 1, 0, wb[14], 2, 1),
    # L15: B4-DW, rd=B1, wr=B0
    make_config(128, 128, 24,  28, 1, 1, 0, 0, 1, wb[15], 1, 0),
    # L16: B4-PW2+Res, rd=B0, res=B2, wr=B1
    make_config(128, 64,  24,  28, 1, 0, 1, 1, 0, wb[16], 0, 1),
    # L17: B5-PW1, 64->256, rd=B1, wr=B2, 28x24
    make_config(64,  256, 24,  28, 1, 1, 0, 1, 0, wb[17], 1, 2),
    # L18: B5-DW, 256ch, stride 2, rd=B2, wr=B0, 28x24->14x12
    make_config(256, 256, 24,  28, 2, 1, 0, 0, 1, wb[18], 2, 0),
    # L19: B5-PW2, 256->128, rd=B0, wr=B2, 14x12, no res
    make_config(256, 128, 12,  14, 1, 0, 0, 1, 0, wb[19], 0, 2),
    # L20: B6-PW1, 128->256, rd=B2, wr=B1, 14x12
    make_config(128, 256, 12,  14, 1, 1, 0, 1, 0, wb[20], 2, 1),
    # L21: B6-DW, 256ch, rd=B1, wr=B0
    make_config(256, 256, 12,  14, 1, 1, 0, 0, 1, wb[21], 1, 0),
    # L22: B6-PW2+Res, 256->128, rd=B0, res=B2, wr=B1
    make_config(256, 128, 12,  14, 1, 0, 1, 1, 0, wb[22], 0, 1),
    # L23: B7-PW1, rd=B1, wr=B2
    make_config(128, 256, 12,  14, 1, 1, 0, 1, 0, wb[23], 1, 2),
    # L24: B7-DW, rd=B2, wr=B0
    make_config(256, 256, 12,  14, 1, 1, 0, 0, 1, wb[24], 2, 0),
    # L25: B7-PW2+Res, rd=B0, res=B1, wr=B2
    make_config(256, 128, 12,  14, 1, 0, 1, 1, 0, wb[25], 0, 2),
    # L26: B8-PW1, rd=B2, wr=B1
    make_config(128, 256, 12,  14, 1, 1, 0, 1, 0, wb[26], 2, 1),
    # L27: B8-DW, rd=B1, wr=B0
    make_config(256, 256, 12,  14, 1, 1, 0, 0, 1, wb[27], 1, 0),
    # L28: B8-PW2+Res, rd=B0, res=B2, wr=B1
    make_config(256, 128, 12,  14, 1, 0, 1, 1, 0, wb[28], 0, 1),
    # L29: B9-PW1, rd=B1, wr=B2
    make_config(128, 256, 12,  14, 1, 1, 0, 1, 0, wb[29], 1, 2),
    # L30: B9-DW, rd=B2, wr=B0
    make_config(256, 256, 12,  14, 1, 1, 0, 0, 1, wb[30], 2, 0),
    # L31: B9-PW2+Res, rd=B0, res=B1, wr=B2
    make_config(256, 128, 12,  14, 1, 0, 1, 1, 0, wb[31], 0, 2),
    # L32: B10-PW1, rd=B2, wr=B1
    make_config(128, 256, 12,  14, 1, 1, 0, 1, 0, wb[32], 2, 1),
    # L33: B10-DW, rd=B1, wr=B0
    make_config(256, 256, 12,  14, 1, 1, 0, 0, 1, wb[33], 1, 0),
    # L34: B10-PW2+Res, rd=B0, res=B2, wr=B1
    make_config(256, 128, 12,  14, 1, 0, 1, 1, 0, wb[34], 0, 1),
    # L35: B11-PW1, rd=B1, wr=B2
    make_config(128, 256, 12,  14, 1, 1, 0, 1, 0, wb[35], 1, 2),
    # L36: B11-DW, rd=B2, wr=B0
    make_config(256, 256, 12,  14, 1, 1, 0, 0, 1, wb[36], 2, 0),
    # L37: B11-PW2+Res, rd=B0, res=B1, wr=B2
    make_config(256, 128, 12,  14, 1, 0, 1, 1, 0, wb[37], 0, 2),
    # L38: B12-PW1, 128->512, rd=B2, wr=B1, 14x12
    make_config(128, 512, 12,  14, 1, 1, 0, 1, 0, wb[38], 2, 1),
    # L39: B12-DW, 512ch, stride 2, rd=B1, wr=B0, 14x12->7x6
    make_config(512, 512, 12,  14, 2, 1, 0, 0, 1, wb[39], 1, 0),
    # L40: B12-PW2, 512->128, rd=B0, wr=B2, 7x6, no res
    make_config(512, 128,  6,   7, 1, 0, 0, 1, 0, wb[40], 0, 2),
    # L41: B13-PW1, 128->256, rd=B2, wr=B1, 7x6
    make_config(128, 256,  6,   7, 1, 1, 0, 1, 0, wb[41], 2, 1),
    # L42: B13-DW, 256ch, rd=B1, wr=B0
    make_config(256, 256,  6,   7, 1, 1, 0, 0, 1, wb[42], 1, 0),
    # L43: B13-PW2+Res, 256->128, rd=B0, res=B2, wr=B1
    make_config(256, 128,  6,   7, 1, 0, 1, 1, 0, wb[43], 0, 1),
    # L44: B14-PW1, 128->256, rd=B1, wr=B2
    make_config(128, 256,  6,   7, 1, 1, 0, 1, 0, wb[44], 1, 2),
    # L45: B14-DW, 256ch, rd=B2, wr=B0
    make_config(256, 256,  6,   7, 1, 1, 0, 0, 1, wb[45], 2, 0),
    # L46: B14-PW2+Res, 256->128, rd=B0, res=B1, wr=B2
    make_config(256, 128,  6,   7, 1, 0, 1, 1, 0, wb[46], 0, 2),
    # L47: Conv2, 128->512, rd=B2, wr=B1, 7x6
    make_config(128, 512,  6,   7, 1, 1, 0, 1, 0, wb[47], 2, 1),
]

assert len(configs) == 48, f"Expected 48 configs, got {len(configs)}"
with open(os.path.join(SIM_DIR, "config.hex"), "w") as f:
    for cfg in configs: f.write(f"{cfg:016x}\n")
    for _ in range(64 - len(configs)): f.write("0000000000000000\n")

print(f"Generated hex files for 48 layers (L0-L47).")
print(f"Weight base for last layer (L47): {wb[47]} (0x{wb[47]:05x})")
