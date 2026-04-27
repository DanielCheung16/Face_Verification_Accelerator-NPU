import os
import sys
import numpy as np

def hex_to_signed_int16(h):
    val = int(h, 16)
    if val >= 0x8000:
        val -= 0x10000
    return val

# Determine which layer to verify
layer = int(sys.argv[1]) if len(sys.argv) > 1 else 1  # default: Layer 1

# Layer parameters
LAYER_PARAMS = {
    0: {"C": 64, "H": 56, "W": 48, "golden": "layer0_out_fixed.txt", "offset": 0x10000},
    1: {"C": 64, "H": 56, "W": 48, "golden": "layer1_out_fixed.txt", "offset": 0x00000},  # ping-pong back
}

if layer not in LAYER_PARAMS:
    print(f"Error: Layer {layer} not supported. Use 0 or 1.")
    exit(1)

params = LAYER_PARAMS[layer]
C, H_out, W_out = params["C"], params["H"], params["W"]
RTL_OUTPUT_OFFSET = params["offset"]

GOLDEN_FILE = f"software/golden/{params['golden']}"
RTL_HEX_FILE = "hardware/frontend/sim/rtl_out.hex"

if not os.path.exists(RTL_HEX_FILE):
    print(f"Error: {RTL_HEX_FILE} not found. Please run 'make top' first.")
    exit(1)

if not os.path.exists(GOLDEN_FILE):
    print(f"Error: {GOLDEN_FILE} not found.")
    exit(1)

# Load Golden (int16 Q10, CHW order)
with open(GOLDEN_FILE, "r") as f:
    golden_list = [int(line.strip()) for line in f]

num_output = C * H_out * W_out
assert len(golden_list) == num_output, \
    f"Golden size {len(golden_list)} != {C}*{H_out}*{W_out}={num_output}"

golden_chw = np.array(golden_list, dtype=np.int32).reshape((C, H_out, W_out))

# Load RTL (hex SRAM dump)
with open(RTL_HEX_FILE, "r") as f:
    rtl_hex = [line.strip() for line in f if line.strip() and not line.startswith("@")]

if RTL_OUTPUT_OFFSET + num_output > len(rtl_hex):
    print(f"Error: RTL hex too small. Has {len(rtl_hex)}, need {RTL_OUTPUT_OFFSET + num_output}.")
    exit(1)

# RTL output is HWC order
rtl_raw = np.array([hex_to_signed_int16(rtl_hex[RTL_OUTPUT_OFFSET + i]) 
                     for i in range(num_output)])
rtl_hwc = rtl_raw.reshape((H_out, W_out, C))
rtl_chw = rtl_hwc.transpose(2, 0, 1)  # -> CHW

# Compare
diffs_abs = np.abs(rtl_chw - golden_chw)
matches_exact = int(np.sum(diffs_abs == 0))
matches_1 = int(np.sum(diffs_abs <= 1))
matches_5 = int(np.sum(diffs_abs <= 5))

print(f"=== Layer {layer} Verification ===")
print(f"Comparing {num_output} pixels (C={C}, H={H_out}, W={W_out})")
print(f"  Golden: {GOLDEN_FILE}")
print(f"  RTL offset: 0x{RTL_OUTPUT_OFFSET:05X}")
print(f"Exact match:  {matches_exact/num_output*100:.2f}% ({matches_exact}/{num_output})")
print(f"Match (±1):   {matches_1/num_output*100:.2f}% ({matches_1}/{num_output})")
print(f"Match (±5):   {matches_5/num_output*100:.2f}% ({matches_5}/{num_output})")
print(f"Mean abs err: {np.mean(diffs_abs):.2f}")
print(f"Max abs err:  {np.max(diffs_abs)}")

# Show first mismatches
mismatch_locs = np.argwhere(diffs_abs > 1)
if len(mismatch_locs) > 0:
    print(f"\nFirst 5 mismatches (diff>1):")
    for idx in mismatch_locs[:5]:
        c, h, w = idx
        g = int(golden_chw[c, h, w])
        r = int(rtl_chw[c, h, w])
        print(f"  (c={c}, h={h}, w={w}): Golden={g}, RTL={r} (Diff={abs(g-r)})")
