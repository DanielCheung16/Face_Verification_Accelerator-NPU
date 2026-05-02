import os

def to_uint16(val):
    try:
        val = int(val)
        if val < 0:
            val = (1 << 16) + val
        return val & 0xFFFF
    except:
        return 0

def to_uint32(val):
    try:
        val = int(val)
        if val < 0:
            val = (1 << 32) + val
        return val & 0xFFFFFFFF
    except:
        return 0

# Paths
FIXED_DIR = "software/golden_weights_fixed"
SIM_DIR = "hardware/frontend/sim"

if not os.path.exists(SIM_DIR):
    os.makedirs(SIM_DIR)

# --- Weights Hex Generation ---
try:
    with open(os.path.join(FIXED_DIR, "conv1_weight.txt"), "r") as f:
        weights = [line.strip() for line in f]
    with open(os.path.join(FIXED_DIR, "conv1_bias.txt"), "r") as f:
        biases = [line.strip() for line in f]
    with open(os.path.join(FIXED_DIR, "conv1_prelu.txt"), "r") as f:
        prelus = [line.strip() for line in f]

    hex_lines = []
    # Layer 0: conv1, 64 output channels, 3 input channels, 3x3 kernel
    for oc in range(64):
        for ic in range(3):
            # Extract 3x3 weights for this (oc, ic)
            idx = (oc * 3 + ic) * 9
            w_block = weights[idx : idx + 9]
            # Bias is 32-bit. Assuming we add it only for the first input channel 
            # to start the accumulation.
            b_val = to_uint32(biases[oc]) if ic == 0 else 0 
            p_val = to_uint16(prelus[oc])
            
            # Format: {prelu[15:0], bias[31:0], w8...w0[143:0]}
            word = (p_val << (32 + 144)) | (b_val << 144)
            for j in range(9):
                word |= (to_uint16(w_block[j]) << (j * 16))
            
            hex_lines.append(f"{word:048x}")

    with open(os.path.join(SIM_DIR, "weights.hex"), "w") as f:
        f.write("\n".join(hex_lines))
    print(f"Generated {len(hex_lines)} words in weights.hex from fixed-point files")
except Exception as e:
    print(f"Error generating weights: {e}")

# --- Input Hex Generation ---
try:
    with open(os.path.join("software/golden", "layer0_in.txt"), "r") as f:
        inputs = [float(line.strip()) for line in f]
    
    in_hex = []
    for val in inputs:
        # Quantize to Q5.10 (as used in hardware)
        q_val = int(round(val * 1024))
        in_hex.append(f"{to_uint16(q_val):04x}")
    
    with open(os.path.join(SIM_DIR, "input.hex"), "w") as f:
        f.write("\n".join(in_hex))
    print(f"Generated {len(in_hex)} words in input.hex")
except Exception as e:
    print(f"Error generating input: {e}")

# --- Config Hex Generation ---
# Format: {ping_pong(1), has_prelu(1), stride(2), height(8), width(8), out_ch(10), in_ch(10)}
# Layer 0 config
in_ch = 3
out_ch = 64
width = 112
height = 112
stride = 2
has_prelu = 1
ping_pong = 0

config0 = (ping_pong << 39) | (has_prelu << 38) | (stride << 36) | (height << 28) | (width << 20) | (out_ch << 10) | in_ch
config_hex = [f"{config0:010x}"] + ["0000000000"] * 57

with open(os.path.join(SIM_DIR, "config.hex"), "w") as f:
    f.write("\n".join(config_hex))
print("Generated config.hex")
