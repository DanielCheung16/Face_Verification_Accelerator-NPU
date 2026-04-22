import torch
import numpy as np
import os
from model import MobileFacenet

# === CONFIGURATION PATHS ===
CKPT_PATH = "../src/068.ckpt"
GOLDEN_WEIGHTS_FIXED_DIR = "../golden_weights_fixed"
F_BITS = 10  # Q5.10 format (1 sign bit + 5 integer bits + 10 fractional bits)
SCALE_W = (1 << F_BITS)
SCALE_B = (1 << (2 * F_BITS))
# ===========================

def float_to_q16(tensor, scale):
    """ Scales and clamps to INT16 """
    q_tensor = torch.round(tensor * scale)
    q_tensor = torch.clamp(q_tensor, -32768, 32767)
    return q_tensor.to(torch.int16).numpy().flatten()

def float_to_q32(tensor, scale):
    """ Scales and clamps to INT32 (Used for bias to match w*x scale) """
    q_tensor = torch.round(tensor * scale)
    q_tensor = torch.clamp(q_tensor, -2147483648, 2147483647)
    return q_tensor.to(torch.int32).numpy().flatten()

def dump_int_tensor(filepath, arr):
    with open(filepath, 'w') as f:
        np.savetxt(f, arr, fmt="%d")

def fuse_conv_bn(conv, bn):
    run_mean = bn.running_mean
    run_var = bn.running_var
    gamma = bn.weight
    beta = bn.bias
    eps = bn.eps
    
    std = torch.sqrt(run_var + eps)
    t = (gamma / std)
    
    t_view = t.view(-1, 1, 1, 1)
    w_fused = conv.weight * t_view
    
    b_conv = conv.bias if conv.bias is not None else torch.zeros_like(run_mean)
    b_fused = beta + (b_conv - run_mean) * t
    
    return w_fused, b_fused

def export_conv_block_fixed(prefix, conv_module, bn_module, prelu_module):
    w, b = fuse_conv_bn(conv_module, bn_module)
    
    # Quantize
    w_q16 = float_to_q16(w, SCALE_W)
    b_q32 = float_to_q32(b, SCALE_B)  # Bias needs 2*F scale because MAC product is W*X
    
    dump_int_tensor(f"{GOLDEN_WEIGHTS_FIXED_DIR}/{prefix}_weight.txt", w_q16)
    dump_int_tensor(f"{GOLDEN_WEIGHTS_FIXED_DIR}/{prefix}_bias.txt", b_q32)
    
    if prelu_module is not None:
        a_q16 = float_to_q16(prelu_module.weight, SCALE_W)
        dump_int_tensor(f"{GOLDEN_WEIGHTS_FIXED_DIR}/{prefix}_prelu.txt", a_q16)

def main():
    if not os.path.exists(GOLDEN_WEIGHTS_FIXED_DIR):
        os.makedirs(GOLDEN_WEIGHTS_FIXED_DIR)

    print(f"Loading Model for INT16 Quantization (F={F_BITS})...")
    device = torch.device("cpu")
    net = MobileFacenet()
    net.eval()

    try:
        checkpoint = torch.load(CKPT_PATH, map_location=device)
        if 'net_state_dict' in checkpoint:
            state_dict = checkpoint['net_state_dict']
            new_state_dict = { (k[7:] if k.startswith('module.') else k): v for k, v in state_dict.items() }
            net.load_state_dict(new_state_dict)
        else:
            net.load_state_dict(checkpoint)
    except FileNotFoundError:
        print("Model checkpoint not found.")
        return

    print(f"Exporting INT16 fixed-point weights to {GOLDEN_WEIGHTS_FIXED_DIR}...")

    export_conv_block_fixed("conv1", net.conv1.conv, net.conv1.bn, net.conv1.prelu)
    export_conv_block_fixed("dw_conv1", net.dw_conv1.conv, net.dw_conv1.bn, net.dw_conv1.prelu)

    for i, btn in enumerate(net.blocks):
        prefix = f"blocks_{i}"
        export_conv_block_fixed(f"{prefix}_pw1", btn.conv[0], btn.conv[1], btn.conv[2])
        export_conv_block_fixed(f"{prefix}_dw", btn.conv[3], btn.conv[4], btn.conv[5])
        export_conv_block_fixed(f"{prefix}_pw2", btn.conv[6], btn.conv[7], None)

    export_conv_block_fixed("conv2", net.conv2.conv, net.conv2.bn, net.conv2.prelu)
    export_conv_block_fixed("linear7", net.linear7.conv, net.linear7.bn, None)
    export_conv_block_fixed("linear1", net.linear1.conv, net.linear1.bn, None)

    print("INT16 weights exported successfully!")

if __name__ == "__main__":
    main()
