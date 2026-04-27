import os
import numpy as np

def hex_to_signed_int16(h):
    val = int(h, 16)
    if val >= 0x8000:
        val -= 0x10000
    return val

GOLDEN_FILE = "./golden/layer0_out_c.txt"
RTL_HEX_FILE = "../hardware/frontend/sim/rtl_out.hex"
RTL_OUTPUT_OFFSET = 65536

with open(GOLDEN_FILE, "r") as f:
    golden_floats = [float(line.strip()) for line in f]

C, H_out, W_out = 64, 56, 48
golden_chw = np.array(golden_floats).reshape((C, H_out, W_out))

with open(RTL_HEX_FILE, "r") as f:
    rtl_hex = [line.strip() for line in f if line.strip() and not line.startswith("@")]

num_output = C * H_out * W_out
rtl_raw = np.array([hex_to_signed_int16(rtl_hex[RTL_OUTPUT_OFFSET + i]) 
                     for i in range(num_output)])
rtl_hwc = rtl_raw.reshape((H_out, W_out, C))
rtl_chw = rtl_hwc.transpose(2, 0, 1)

golden_q10 = np.round(golden_chw * 1024).astype(int)

print(f"Comparing {num_output} output pixels (C={C}, H={H_out}, W={W_out})...")
for tol in [1, 2, 5, 10, 20, 50]:
    matches = np.sum(np.abs(rtl_chw - golden_q10) <= tol)
    print(f"  Tolerance ±{tol:2d}: Match rate = {matches/num_output*100:.2f}% ({matches}/{num_output})")

# Stats on differences
diffs = np.abs(rtl_chw - golden_q10).flatten()
print(f"\nError statistics:")
print(f"  Mean abs error:   {np.mean(diffs):.2f}")
print(f"  Max abs error:    {np.max(diffs)}")
print(f"  Median abs error: {np.median(diffs):.2f}")
print(f"  95th percentile:  {np.percentile(diffs, 95):.2f}")
