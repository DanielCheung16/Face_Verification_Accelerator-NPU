import numpy as np
import os

# Paths
FIXED_W_DIR = "software/golden_weights_fixed"
GOLDEN_DIR = "software/golden"

def load_fixed(filename):
    with open(os.path.join(FIXED_W_DIR, filename), 'r') as f:
        return np.array([int(line.strip()) for line in f])

def save_fixed(filename, data):
    with open(os.path.join(GOLDEN_DIR, filename), 'w') as f:
        for val in data.flatten():
            f.write(f"{int(val)}\n")

def conv2d_fixed(inp, wgt, bias, alpha, stride, padding, has_prelu, is_dw):
    c_out, c_in, kh, kw = wgt.shape
    batch, c_in_inp, h_in, w_in = inp.shape
    h_out = (h_in + 2*padding - kh) // stride + 1
    w_out = (w_in + 2*padding - kw) // stride + 1
    
    out = np.zeros((batch, c_out, h_out, w_out), dtype=np.int32)
    inp_padded = np.pad(inp, ((0,0), (0,0), (padding, padding), (padding, padding)), mode='constant')
    
    for oc in range(c_out):
        for oh in range(h_out):
            for ow in range(w_out):
                acc = int(bias[oc])
                if is_dw:
                    patch = inp_padded[0, oc, oh*stride:oh*stride+kh, ow*stride:ow*stride+kw]
                    acc += np.sum(patch.astype(np.int32) * wgt[oc, 0].astype(np.int32))
                else:
                    patch = inp_padded[0, :, oh*stride:oh*stride+kh, ow*stride:ow*stride+kw]
                    acc += np.sum(patch.astype(np.int32) * wgt[oc].astype(np.int32))
                val = acc >> 10
                val = max(-32768, min(32767, val))
                out[0, oc, oh, ow] = val
    
    if has_prelu:
        for oc in range(c_out):
            a = int(alpha[oc])
            for oh in range(h_out):
                for ow in range(w_out):
                    if out[0, oc, oh, ow] < 0:
                        scaled = out[0, oc, oh, ow] * a
                        out[0, oc, oh, ow] = scaled >> 10
    return out.astype(np.int16)

# Main
print("Generating Golden for Layer 0-7...")
with open('software/golden/layer0_in.txt', 'r') as f:
    img_float = np.array([float(line.strip()) for line in f])
img = np.round(img_float.reshape((1, 3, 112, 96)) * 1024).astype(np.int16)

# L0: Conv1
l0_out = conv2d_fixed(img, load_fixed("conv1_weight.txt").reshape(64, 3, 3, 3), 
                      load_fixed("conv1_bias.txt"), load_fixed("conv1_prelu.txt"), 2, 1, True, False)
save_fixed("layer0_out_fixed.txt", l0_out)

# L1: DW1
l1_out = conv2d_fixed(l0_out, load_fixed("dw_conv1_weight.txt").reshape(64, 1, 3, 3), 
                      load_fixed("dw_conv1_bias.txt"), load_fixed("dw_conv1_prelu.txt"), 1, 1, True, True)
save_fixed("layer1_out_fixed.txt", l1_out)

# L2: PW1 (Block 0 expansion)
l2_out = conv2d_fixed(l1_out, load_fixed("blocks_0_pw1_weight.txt").reshape(128, 64, 1, 1), 
                      load_fixed("blocks_0_pw1_bias.txt"), load_fixed("blocks_0_pw1_prelu.txt"), 1, 0, True, False)
save_fixed("layer2_out_fixed.txt", l2_out)

# L3: DW2 (Block 0 depthwise, stride 2)
l3_out = conv2d_fixed(l2_out, load_fixed("blocks_0_dw_weight.txt").reshape(128, 1, 3, 3), 
                      load_fixed("blocks_0_dw_bias.txt"), load_fixed("blocks_0_dw_prelu.txt"), 2, 1, True, True)
save_fixed("layer3_out_fixed.txt", l3_out)

# L4: PW2 (Block 0 projection)
l4_out = conv2d_fixed(l3_out, load_fixed("blocks_0_pw2_weight.txt").reshape(64, 128, 1, 1), 
                      load_fixed("blocks_0_pw2_bias.txt"), None, 1, 0, False, False)
save_fixed("layer4_out_fixed.txt", l4_out)

# L5: PW3 (Block 1 expansion)
l5_out = conv2d_fixed(l4_out, load_fixed("blocks_1_pw1_weight.txt").reshape(128, 64, 1, 1), 
                      load_fixed("blocks_1_pw1_bias.txt"), load_fixed("blocks_1_pw1_prelu.txt"), 1, 0, True, False)
save_fixed("layer5_out_fixed.txt", l5_out)

# L6: DW3 (Block 1 depthwise)
l6_out = conv2d_fixed(l5_out, load_fixed("blocks_1_dw_weight.txt").reshape(128, 1, 3, 3), 
                      load_fixed("blocks_1_dw_bias.txt"), load_fixed("blocks_1_dw_prelu.txt"), 1, 1, True, True)
save_fixed("layer6_out_fixed.txt", l6_out)

# L7: PW4 (Block 1 projection) + RESIDUAL
l7_conv = conv2d_fixed(l6_out, load_fixed("blocks_1_pw2_weight.txt").reshape(64, 128, 1, 1), 
                       load_fixed("blocks_1_pw2_bias.txt"), None, 1, 0, False, False)
l7_res = l7_conv + l4_out # Shortcut from l4_out
save_fixed("layer7_out_fixed.txt", l7_res)

print("Layer 0-7 Golden Generated.")

# ---- Vectorized helpers for L8-L47 ----------------------------------------

def pw_conv_fast(inp, wgt, bias, alpha, has_prelu):
    """Pointwise (1x1) conv in Q10 fixed-point, vectorized over all spatial positions."""
    c_in, h, w = inp.shape[1], inp.shape[2], inp.shape[3]
    c_out = wgt.shape[0]
    W = wgt[:, :, 0, 0].astype(np.int64)                       # (c_out, c_in)
    I = inp[0].reshape(c_in, h * w).astype(np.int64)           # (c_in, h*w)
    out = (W @ I) + bias[:, np.newaxis].astype(np.int64)        # (c_out, h*w)
    out = out >> 10
    out = np.clip(out, -32768, 32767)
    if has_prelu:
        neg = out < 0
        prelu = np.clip((out * alpha[:, np.newaxis].astype(np.int64)) >> 10, -32768, 32767)
        out = np.where(neg, prelu, out)
    return out.reshape(1, c_out, h, w).astype(np.int16)


def dw_conv_fast(inp, wgt, bias, alpha, stride, has_prelu):
    """Depthwise 3x3 conv in Q10 fixed-point, vectorized over channels."""
    c = inp.shape[1]
    h_in, w_in = inp.shape[2], inp.shape[3]
    h_out = (h_in - 1) // stride + 1
    w_out = (w_in - 1) // stride + 1
    padded = np.pad(inp[0], ((0, 0), (1, 1), (1, 1)), mode='constant').astype(np.int64)
    out = np.zeros((c, h_out, w_out), dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            out += wgt[:, 0, kh, kw][:, np.newaxis, np.newaxis] * \
                   padded[:, kh::stride, kw::stride][:, :h_out, :w_out]
    out += bias[:, np.newaxis, np.newaxis].astype(np.int64)
    out = out >> 10
    out = np.clip(out, -32768, 32767)
    if has_prelu:
        neg = out < 0
        prelu = np.clip((out * alpha[:, np.newaxis, np.newaxis].astype(np.int64)) >> 10, -32768, 32767)
        out = np.where(neg, prelu, out)
    return out.reshape(1, c, h_out, w_out).astype(np.int16)


def res_add(a, b):
    """Residual addition with int16 clamping (matches hardware behavior)."""
    return np.clip(a.astype(np.int32) + b.astype(np.int32), -32768, 32767).astype(np.int16)


def bottleneck_fast(inp, name, c_mid, c_out, stride, l_start):
    """Run one bottleneck block and save the three layer outputs."""
    c_in = inp.shape[1]
    # PW1
    pw1 = pw_conv_fast(inp,
                       load_fixed(f"{name}_pw1_weight.txt").reshape(c_mid, c_in, 1, 1),
                       load_fixed(f"{name}_pw1_bias.txt"),
                       load_fixed(f"{name}_pw1_prelu.txt"), True)
    save_fixed(f"layer{l_start}_out_fixed.txt", pw1)
    # DW
    dw = dw_conv_fast(pw1,
                      load_fixed(f"{name}_dw_weight.txt").reshape(c_mid, 1, 3, 3),
                      load_fixed(f"{name}_dw_bias.txt"),
                      load_fixed(f"{name}_dw_prelu.txt"), stride, True)
    save_fixed(f"layer{l_start+1}_out_fixed.txt", dw)
    # PW2
    pw2 = pw_conv_fast(dw,
                       load_fixed(f"{name}_pw2_weight.txt").reshape(c_out, c_mid, 1, 1),
                       load_fixed(f"{name}_pw2_bias.txt"),
                       None, False)
    if stride == 1 and c_in == c_out:
        pw2 = res_add(pw2, inp)
    save_fixed(f"layer{l_start+2}_out_fixed.txt", pw2)
    return pw2


# ---- Layers 8-47 -----------------------------------------------------------
print("Generating Golden for Layer 8-47...")

# L8-10: Block 2 (64->128->64, stride 1, residual from L7)
cur = bottleneck_fast(l7_res, "blocks_2", 128, 64, 1,  8)
# L11-13: Block 3
cur = bottleneck_fast(cur,    "blocks_3", 128, 64, 1, 11)
# L14-16: Block 4
cur = bottleneck_fast(cur,    "blocks_4", 128, 64, 1, 14)
# L17-19: Block 5 (64->256->128, stride 2, no residual)
cur = bottleneck_fast(cur,    "blocks_5", 256, 128, 2, 17)
# L20-22: Block 6 (128->256->128, stride 1, residual)
cur = bottleneck_fast(cur,    "blocks_6", 256, 128, 1, 20)
# L23-25: Block 7
cur = bottleneck_fast(cur,    "blocks_7", 256, 128, 1, 23)
# L26-28: Block 8
cur = bottleneck_fast(cur,    "blocks_8", 256, 128, 1, 26)
# L29-31: Block 9
cur = bottleneck_fast(cur,    "blocks_9", 256, 128, 1, 29)
# L32-34: Block 10
cur = bottleneck_fast(cur,    "blocks_10", 256, 128, 1, 32)
# L35-37: Block 11
cur = bottleneck_fast(cur,    "blocks_11", 256, 128, 1, 35)
# L38-40: Block 12 (128->512->128, stride 2, no residual)
cur = bottleneck_fast(cur,    "blocks_12", 512, 128, 2, 38)
# L41-43: Block 13 (128->256->128, stride 1, residual)
cur = bottleneck_fast(cur,    "blocks_13", 256, 128, 1, 41)
# L44-46: Block 14
cur = bottleneck_fast(cur,    "blocks_14", 256, 128, 1, 44)

# L47: Conv2 (128->512, 1x1, PReLU)
l47 = pw_conv_fast(cur,
                   load_fixed("conv2_weight.txt").reshape(512, 128, 1, 1),
                   load_fixed("conv2_bias.txt"),
                   load_fixed("conv2_prelu.txt"), True)
save_fixed("layer47_out_fixed.txt", l47)

print("Layer 8-47 Golden Generated.")

# L48: linear7 (global DW, 7×6 kernel, 512ch, no PReLU, no residual)
print("Generating Golden for Layer 48 (linear7)...")

l48_wgt = load_fixed("linear7_weight.txt")  # 512 * 42 = 21504 entries
l48_bias = load_fixed("linear7_bias.txt")   # 512 entries

# Reshape: (512, 1, 7, 6) for DW conv
wgt48 = np.array(l48_wgt).reshape(512, 1, 7, 6).astype(np.int64)
bias48 = np.array(l48_bias).astype(np.int64)

# Input is l47: (1, 512, 7, 6) — output of L47 (Conv2)
inp48 = l47[0].astype(np.int64)  # (512, 7, 6)

# Global DW: no padding, kernel = input spatial → output is (512, 1, 1)
out48 = np.zeros((512,), dtype=np.int64)
for c in range(512):
    acc = bias48[c]
    for kh in range(7):
        for kw in range(6):
            acc += inp48[c, kh, kw] * wgt48[c, 0, kh, kw]
    val = acc >> 10
    val = int(np.clip(val, -32768, 32767))
    out48[c] = val

l48 = out48.reshape(1, 512, 1, 1).astype(np.int16)
save_fixed("layer48_out_fixed.txt", l48)

print("Layer 48 (linear7) Golden Generated.")

# L49: linear1 (1x1 PW, 512->128, no PReLU)
print("Generating Golden for Layer 49 (linear1)...")

l49_wgt = load_fixed("linear1_weight.txt")  # 128 * 512 = 65536 entries
l49_bias = load_fixed("linear1_bias.txt")   # 128 entries

wgt49 = np.array(l49_wgt).reshape(128, 512).astype(np.int64)
bias49 = np.array(l49_bias).astype(np.int64)

# Input is l48: (1, 512, 1, 1) → flatten to (512,)
inp49 = l48[0, :, 0, 0].astype(np.int64)  # (512,)

out49 = np.zeros((128,), dtype=np.int64)
for oc in range(128):
    acc = bias49[oc] + np.sum(inp49 * wgt49[oc])
    val = acc >> 10
    val = int(np.clip(val, -32768, 32767))
    out49[oc] = val

l49 = out49.reshape(1, 128, 1, 1).astype(np.int16)
save_fixed("layer49_out_fixed.txt", l49)

print("Layer 49 (linear1) Golden Generated.")
