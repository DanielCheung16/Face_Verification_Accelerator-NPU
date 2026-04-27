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
