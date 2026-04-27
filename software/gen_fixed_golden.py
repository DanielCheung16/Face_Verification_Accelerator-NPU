#!/usr/bin/env python3
"""
Generate layer0 fixed-point golden output.
Replicates the EXACT computation of c_model_fixed/conv.c + activation.c.
Uses golden_weights_fixed/ (pre-quantized int16/int32).
"""
import numpy as np

# 1. Load input (float) -> quantize to Q10 int16
with open('software/golden/layer0_in.txt', 'r') as f:
    img_float = np.array([float(line.strip()) for line in f])
# CHW: C=3, H=112, W=96
img_chw = img_float.reshape((3, 112, 96))
img_q10 = np.round(img_chw * 1024).astype(np.int16)

# 2. Load pre-quantized weights (int16 Q10)
with open('software/golden_weights_fixed/conv1_weight.txt', 'r') as f:
    wgt = np.array([int(line.strip()) for line in f], dtype=np.int16)
wgt = wgt.reshape((64, 3, 3, 3))  # OutCh, InCh, KH, KW

# 3. Load pre-quantized bias (int32 Q20)
with open('software/golden_weights_fixed/conv1_bias.txt', 'r') as f:
    bias = np.array([int(line.strip()) for line in f], dtype=np.int32)

# 4. Load pre-quantized PReLU alpha (int16 Q10)
with open('software/golden_weights_fixed/conv1_prelu.txt', 'r') as f:
    prelu_alpha = np.array([int(line.strip()) for line in f], dtype=np.int16)

# 5. Fixed-point Conv2d (same as c_model_fixed/conv.c)
stride, padding = 2, 1
in_c, in_h, in_w = 3, 112, 96
out_c = 64
out_h = (in_h + 2 * padding - 3) // stride + 1  # = 56
out_w = (in_w + 2 * padding - 3) // stride + 1   # = 48

print(f"Computing fixed-point conv: ({in_c},{in_h},{in_w}) -> ({out_c},{out_h},{out_w})")

output = np.zeros((out_c, out_h, out_w), dtype=np.int16)

for oc in range(out_c):
    for oh in range(out_h):
        for ow in range(out_w):
            # int32 accumulator, initialized with bias (Q20)
            acc = int(bias[oc])  # Python int for no overflow
            
            for ic in range(in_c):
                for kh in range(3):
                    for kw in range(3):
                        ih = oh * stride - padding + kh
                        iw = ow * stride - padding + kw
                        if 0 <= ih < in_h and 0 <= iw < in_w:
                            acc += int(img_q10[ic, ih, iw]) * int(wgt[oc, ic, kh, kw])
            
            # Quantize: Q20 >> 10 = Q10, clamp to int16
            val = acc >> 10
            val = max(-32768, min(32767, val))
            output[oc, oh, ow] = val
    
    if oc % 16 == 0:
        print(f"  Channel {oc}/64 done")

# 6. PReLU (same as c_model_fixed/activation.c)
# PReLU on Q10 values: if val < 0: val = (val * alpha) >> 10
for c in range(out_c):
    alpha = int(prelu_alpha[c])
    for h in range(out_h):
        for w in range(out_w):
            if output[c, h, w] < 0:
                scaled = int(output[c, h, w]) * alpha  # Q10 * Q10 = Q20
                output[c, h, w] = np.int16(scaled >> 10)  # Q20 >> 10 = Q10

# 7. Save (CHW, int16, one value per line)
with open('software/golden/layer0_out_fixed.txt', 'w') as f:
    for val in output.flatten():
        f.write(f"{int(val)}\n")

print(f"Saved {output.size} values to software/golden/layer0_out_fixed.txt")
print(f"Sample: output[0,0,0] = {output[0,0,0]}, output[0,0,1] = {output[0,0,1]}")
