import os
import sys
import numpy as np

_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))

def hex_to_signed_int16(h):
    val = int(h, 16)
    if val >= 0x8000:
        val -= 0x10000
    return val

layer = int(sys.argv[1]) if len(sys.argv) > 1 else 0

# 1M SRAM buffer base addresses
B0 = 0x00000
B1 = 0x54000
B2 = 0xA8000

# fmt: (C_out, H_out, W_out, wr_buf_base)
LAYER_PARAMS = {
     0: {"C":  64, "H": 56, "W": 48, "offset": B1},  # Conv1
     1: {"C":  64, "H": 56, "W": 48, "offset": B2},  # DW1
     2: {"C": 128, "H": 56, "W": 48, "offset": B1},  # B0-PW1
     3: {"C": 128, "H": 28, "W": 24, "offset": B2},  # B0-DW  (stride 2)
     4: {"C":  64, "H": 28, "W": 24, "offset": B1},  # B0-PW2
     5: {"C": 128, "H": 28, "W": 24, "offset": B2},  # B1-PW1
     6: {"C": 128, "H": 28, "W": 24, "offset": B0},  # B1-DW
     7: {"C":  64, "H": 28, "W": 24, "offset": B2},  # B1-PW2+Res
     8: {"C": 128, "H": 28, "W": 24, "offset": B1},  # B2-PW1
     9: {"C": 128, "H": 28, "W": 24, "offset": B0},  # B2-DW
    10: {"C":  64, "H": 28, "W": 24, "offset": B1},  # B2-PW2+Res
    11: {"C": 128, "H": 28, "W": 24, "offset": B2},  # B3-PW1
    12: {"C": 128, "H": 28, "W": 24, "offset": B0},  # B3-DW
    13: {"C":  64, "H": 28, "W": 24, "offset": B2},  # B3-PW2+Res
    14: {"C": 128, "H": 28, "W": 24, "offset": B1},  # B4-PW1
    15: {"C": 128, "H": 28, "W": 24, "offset": B0},  # B4-DW
    16: {"C":  64, "H": 28, "W": 24, "offset": B1},  # B4-PW2+Res
    17: {"C": 256, "H": 28, "W": 24, "offset": B2},  # B5-PW1  (64->256)
    18: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B5-DW   (stride 2)
    19: {"C": 128, "H": 14, "W": 12, "offset": B2},  # B5-PW2
    20: {"C": 256, "H": 14, "W": 12, "offset": B1},  # B6-PW1
    21: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B6-DW
    22: {"C": 128, "H": 14, "W": 12, "offset": B1},  # B6-PW2+Res
    23: {"C": 256, "H": 14, "W": 12, "offset": B2},  # B7-PW1
    24: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B7-DW
    25: {"C": 128, "H": 14, "W": 12, "offset": B2},  # B7-PW2+Res
    26: {"C": 256, "H": 14, "W": 12, "offset": B1},  # B8-PW1
    27: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B8-DW
    28: {"C": 128, "H": 14, "W": 12, "offset": B1},  # B8-PW2+Res
    29: {"C": 256, "H": 14, "W": 12, "offset": B2},  # B9-PW1
    30: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B9-DW
    31: {"C": 128, "H": 14, "W": 12, "offset": B2},  # B9-PW2+Res
    32: {"C": 256, "H": 14, "W": 12, "offset": B1},  # B10-PW1
    33: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B10-DW
    34: {"C": 128, "H": 14, "W": 12, "offset": B1},  # B10-PW2+Res
    35: {"C": 256, "H": 14, "W": 12, "offset": B2},  # B11-PW1
    36: {"C": 256, "H": 14, "W": 12, "offset": B0},  # B11-DW
    37: {"C": 128, "H": 14, "W": 12, "offset": B2},  # B11-PW2+Res
    38: {"C": 512, "H": 14, "W": 12, "offset": B1},  # B12-PW1 (128->512)
    39: {"C": 512, "H":  7, "W":  6, "offset": B0},  # B12-DW  (stride 2)
    40: {"C": 128, "H":  7, "W":  6, "offset": B2},  # B12-PW2
    41: {"C": 256, "H":  7, "W":  6, "offset": B1},  # B13-PW1
    42: {"C": 256, "H":  7, "W":  6, "offset": B0},  # B13-DW
    43: {"C": 128, "H":  7, "W":  6, "offset": B1},  # B13-PW2+Res
    44: {"C": 256, "H":  7, "W":  6, "offset": B2},  # B14-PW1
    45: {"C": 256, "H":  7, "W":  6, "offset": B0},  # B14-DW
    46: {"C": 128, "H":  7, "W":  6, "offset": B2},  # B14-PW2+Res
    47: {"C": 512, "H":  7, "W":  6, "offset": B1},  # Conv2   (128->512)
    48: {"C": 512, "H":  1, "W":  1, "offset": B0},  # linear7 (global DW, 1×1 out)
    49: {"C": 128, "H":  1, "W":  1, "offset": B1},  # linear1 (1×1 PW, 512->128)
}

if layer not in LAYER_PARAMS:
    print(f"Error: Layer {layer} not in range 0-48.")
    exit(1)

params = LAYER_PARAMS[layer]
C, H_out, W_out = params["C"], params["H"], params["W"]
RTL_OUTPUT_OFFSET = params["offset"]

GOLDEN_FILE  = os.path.join(_ROOT, f"software/golden/layer{layer}_out_fixed.txt")
RTL_HEX_FILE = os.path.join(_ROOT, f"hardware/frontend/sim/layer_hex/rtl_out_layer{layer}.hex")
if not os.path.exists(RTL_HEX_FILE):
    RTL_HEX_FILE = os.path.join(_ROOT, "hardware/frontend/sim/hex/rtl_out.hex")

if not os.path.exists(RTL_HEX_FILE):
    print(f"Error: RTL hex file not found.")
    exit(1)

with open(GOLDEN_FILE, "r") as f:
    golden_list = [int(line.strip()) for line in f]

num_output  = C * H_out * W_out
golden_chw  = np.array(golden_list, dtype=np.int32).reshape((C, H_out, W_out))

with open(RTL_HEX_FILE, "r") as f:
    rtl_hex = [line.strip() for line in f if line.strip() and not line.startswith("@")]

rtl_raw  = np.array([hex_to_signed_int16(rtl_hex[RTL_OUTPUT_OFFSET + i]) for i in range(num_output)])
rtl_hwc  = rtl_raw.reshape((H_out, W_out, C))
rtl_chw  = rtl_hwc.transpose(2, 0, 1)

diffs_abs    = np.abs(rtl_chw.astype(np.int32) - golden_chw.astype(np.int32))
matches_exact = int(np.sum(diffs_abs == 0))
matches_1    = int(np.sum(diffs_abs <= 1))

print(f"=== Layer {layer} Verification ===")
print(f"Comparing {num_output} pixels (C={C}, H={H_out}, W={W_out})")
print(f"Exact match:  {matches_exact/num_output*100:.2f}% ({matches_exact}/{num_output})")
print(f"Match (±1):   {matches_1/num_output*100:.2f}% ({matches_1}/{num_output})")
print(f"Mean abs err: {np.mean(diffs_abs):.2f}")
print(f"Max abs err:  {np.max(diffs_abs)}")

mismatch_locs = np.argwhere(diffs_abs > 1)
if len(mismatch_locs) > 0:
    print(f"\nFirst 5 mismatches (diff>1):")
    for idx in mismatch_locs[:5]:
        c, h, w = idx
        g = int(golden_chw[c, h, w])
        r = int(rtl_chw[c, h, w])
        print(f"  (c={c}, h={h}, w={w}): Golden={g}, RTL={r} (Diff={abs(g-r)})")
