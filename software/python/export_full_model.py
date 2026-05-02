import torch
import numpy as np
import os
from model import MobileFacenet

# === CONFIGURATION PATHS ===
CKPT_PATH = "../src/068.ckpt"
GOLDEN_WEIGHTS_DIR = "../golden_weights"
# ===========================

def dump_tensor(filepath, tensor):
    arr = tensor.detach().numpy().flatten()
    with open(filepath, 'w') as f:
        np.savetxt(f, arr, fmt="%.6f")

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

def export_conv_block(prefix, conv_module, bn_module, prelu_module):
    w, b = fuse_conv_bn(conv_module, bn_module)
    dump_tensor(f"{GOLDEN_WEIGHTS_DIR}/{prefix}_weight.txt", w)
    dump_tensor(f"{GOLDEN_WEIGHTS_DIR}/{prefix}_bias.txt", b)
    if prelu_module is not None:
        dump_tensor(f"{GOLDEN_WEIGHTS_DIR}/{prefix}_prelu.txt", prelu_module.weight)

def main():
    if not os.path.exists(GOLDEN_WEIGHTS_DIR):
        os.makedirs(GOLDEN_WEIGHTS_DIR)

    print("Loading Model...")
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
        print("Warning: Model checkpoint not found. Exporting random weights.")

    print(f"Exporting all fused weights to {GOLDEN_WEIGHTS_DIR}...")

    # 1. Conv1 & DW_Conv1
    export_conv_block("conv1", net.conv1.conv, net.conv1.bn, net.conv1.prelu)
    export_conv_block("dw_conv1", net.dw_conv1.conv, net.dw_conv1.bn, net.dw_conv1.prelu)

    # 2. Bottlenecks (15 blocks)
    for i, btn in enumerate(net.blocks):
        prefix = f"blocks_{i}"
        # PW1
        export_conv_block(f"{prefix}_pw1", btn.conv[0], btn.conv[1], btn.conv[2])
        # DW
        export_conv_block(f"{prefix}_dw", btn.conv[3], btn.conv[4], btn.conv[5])
        # PW2 (Linear, no PReLU)
        export_conv_block(f"{prefix}_pw2", btn.conv[6], btn.conv[7], None)
        print(f"  - Exported Bottleneck {i}")

    # 3. Post-blocks Conv layers
    export_conv_block("conv2", net.conv2.conv, net.conv2.bn, net.conv2.prelu)
    
    # 4. Linear7 (DW, linear=True -> no PReLU)
    export_conv_block("linear7", net.linear7.conv, net.linear7.bn, None)
    
    # 5. Linear1 (PW, linear=True -> no PReLU)
    export_conv_block("linear1", net.linear1.conv, net.linear1.bn, None)

    print("All weights exported successfully!")

if __name__ == "__main__":
    main()
