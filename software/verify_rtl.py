import os
import sys
import numpy as np

def hex_to_signed_int16(h):
    val = int(h, 16)
    if val >= 0x8000:
        val -= 0x10000
    return val

layer = int(sys.argv[1]) if len(sys.argv) > 1 else 0

# New 1M SRAM offsets: 0x0, 0x54000, 0xA8000 (Step = 344,064 words)
B0 = 0x00000
B1 = 0x54000
B2 = 0xA8000

LAYER_PARAMS = {
    0: {"C": 64,  "H": 56, "W": 48, "golden": "layer0_out_fixed.txt", "offset": B1}, # wr_buf=1
    1: {"C": 64,  "H": 56, "W": 48, "golden": "layer1_out_fixed.txt", "offset": B2}, # wr_buf=2
    2: {"C": 128, "H": 56, "W": 48, "golden": "layer2_out_fixed.txt", "offset": B1}, # wr_buf=1
    3: {"C": 128, "H": 28, "W": 24, "golden": "layer3_out_fixed.txt", "offset": B2}, # wr_buf=2
    4: {"C": 64,  "H": 28, "W": 24, "golden": "layer4_out_fixed.txt", "offset": B1}, # wr_buf=1
    5: {"C": 128, "H": 28, "W": 24, "golden": "layer5_out_fixed.txt", "offset": B2}, # wr_buf=2
    6: {"C": 128, "H": 28, "W": 24, "golden": "layer6_out_fixed.txt", "offset": B0}, # wr_buf=0
    7: {"C": 64,  "H": 28, "W": 24, "golden": "layer7_out_fixed.txt", "offset": B2}, # wr_buf=2 (Proj writes to B2, adds B1)
}

if layer not in LAYER_PARAMS:
    print(f"Error: Layer {layer} not supported.")
    exit(1)

params = LAYER_PARAMS[layer]
C, H_out, W_out = params["C"], params["H"], params["W"]
RTL_OUTPUT_OFFSET = params["offset"]

GOLDEN_FILE = f"software/golden/{params['golden']}"
RTL_HEX_FILE = f"hardware/frontend/sim/hex/rtl_out_layer{layer}.hex"
if not os.path.exists(RTL_HEX_FILE):
    RTL_HEX_FILE = "hardware/frontend/sim/hex/rtl_out.hex"

if not os.path.exists(RTL_HEX_FILE):
    print(f"Error: RTL hex file not found.")
    exit(1)

with open(GOLDEN_FILE, "r") as f:
    golden_list = [int(line.strip()) for line in f]

num_output = C * H_out * W_out
golden_chw = np.array(golden_list, dtype=np.int32).reshape((C, H_out, W_out))

with open(RTL_HEX_FILE, "r") as f:
    rtl_hex = [line.strip() for line in f if line.strip() and not line.startswith("@")]

rtl_raw = np.array([hex_to_signed_int16(rtl_hex[RTL_OUTPUT_OFFSET + i]) for i in range(num_output)])
rtl_hwc = rtl_raw.reshape((H_out, W_out, C))
rtl_chw = rtl_hwc.transpose(2, 0, 1)

diffs_abs = np.abs(rtl_chw.astype(np.int32) - golden_chw.astype(np.int32))
matches_exact = int(np.sum(diffs_abs == 0))
matches_1 = int(np.sum(diffs_abs <= 1))

print(f"=== Layer {layer} Verification ===")
print(f"Comparing {num_output} pixels (C={C}, H={H_out}, W={W_out})")
print(f"Exact match:  {matches_exact/num_output*100:.2f}% ({matches_exact}/{num_output})")
print(f"Match (±1):   {matches_1/num_output*100:.2f}% ({matches_1}/{num_output})")
print(f"Mean abs err: {np.mean(diffs_abs):.2f}")
print(f"Max abs err:  {np.max(diffs_abs)}")

# Show mismatches
mismatch_locs = np.argwhere(diffs_abs > 1)
if len(mismatch_locs) > 0:
    print(f"\nFirst 5 mismatches (diff>1):")
    for idx in mismatch_locs[:5]:
        c, h, w = idx
        g = int(golden_chw[c, h, w])
        r = int(rtl_chw[c, h, w])
        print(f"  (c={c}, h={h}, w={w}): Golden={g}, RTL={r} (Diff={abs(g-r)})")
