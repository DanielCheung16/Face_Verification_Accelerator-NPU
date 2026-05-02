import torch
import numpy as np
import os
import subprocess
from model import MobileFacenet

# === CONFIGURATION PATHS ===
CKPT_PATH = "../src/068.ckpt"
GOLDEN_DIR = "../golden"
C_MODEL_EXE = "../c_model/c_golden_model"
# ===========================


def dump_tensor(filepath, tensor):
    """ Dumps a PyTorch tensor (flattened) to a line-separated text file. """
    arr = tensor.detach().numpy().flatten()
    with open(filepath, 'w') as f:
        np.savetxt(f, arr, fmt="%.6f")

def fuse_conv_bn(conv, bn):
    """
    Fuses a Conv2d and a BatchNorm2d layer into a single Weight and Bias tensor.
    returns: w_fused, b_fused
    """
    w_conv = conv.weight.clone().view(conv.out_channels, -1)
    
    # BN params
    run_mean = bn.running_mean
    run_var = bn.running_var
    gamma = bn.weight
    beta = bn.bias
    eps = bn.eps
    
    # Fusion factors
    std = torch.sqrt(run_var + eps)
    t = (gamma / std)
    
    t_view = t.view(-1, 1, 1, 1)
    w_fused = conv.weight * t_view
    
    b_conv = conv.bias if conv.bias is not None else torch.zeros_like(run_mean)
    b_fused = beta + (b_conv - run_mean) * t
    
    return w_fused, b_fused

def export_conv_block(prefix, conv_module, bn_module, prelu_module, input_tensor):
    w, b = fuse_conv_bn(conv_module, bn_module)
    dump_tensor(f"{GOLDEN_DIR}/{prefix}_weight.txt", w)
    dump_tensor(f"{GOLDEN_DIR}/{prefix}_bias.txt", b)
    if prelu_module is not None:
        dump_tensor(f"{GOLDEN_DIR}/{prefix}_prelu.txt", prelu_module.weight)
    dump_tensor(f"{GOLDEN_DIR}/{prefix}_in.txt", input_tensor)

    # Calculate standard execution
    x = conv_module(input_tensor)
    x = bn_module(x)
    if prelu_module is not None:
        x = prelu_module(x)
        
    dump_tensor(f"{GOLDEN_DIR}/{prefix}_out_pytorch.txt", x)
    return x

def main():
    if not os.path.exists(GOLDEN_DIR):
        os.makedirs(GOLDEN_DIR)

    print("1. Loading Model...")
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
        print("Model checkpoint not found. Using randomly initialized weights.")

    print("2. Exporting Golden Tensors (Conv1, DW_Conv1, Bottleneck)...")
    np.random.seed(42)
    input_np = np.random.randn(1, 3, 112, 96).astype(np.float32)
    x = torch.tensor(input_np)

    # --- Layer 0: Standard Conv (conv1) ---
    print("   -> Exporting Layer 0 (Standard Conv)")
    with torch.no_grad():
        x = export_conv_block("layer0", net.conv1.conv, net.conv1.bn, net.conv1.prelu, x)

    # --- Layer 1: Depthwise Conv (dw_conv1) ---
    print("   -> Exporting Layer 1 (Depthwise Conv)")
    with torch.no_grad():
        x = export_conv_block("layer1", net.dw_conv1.conv, net.dw_conv1.bn, net.dw_conv1.prelu, x)

    # --- Layer 2: Bottleneck (blocks[0]) ---
    print("   -> Exporting Layer 2 (Bottleneck Block 0)")
    btn = net.blocks[0]
    # Input to Bottleneck (will be used for residual add)
    btn_input = x.clone()
    
    with torch.no_grad():
        # PW (1x1)
        x = export_conv_block("layer2_pw1", btn.conv[0], btn.conv[1], btn.conv[2], x)
        # DW (3x3)
        x = export_conv_block("layer2_dw", btn.conv[3], btn.conv[4], btn.conv[5], x)
        # PW Linear (1x1, no prelu)
        x = export_conv_block("layer2_pw2", btn.conv[6], btn.conv[7], None, x)
        
    # --- Layer 3: Bottleneck (blocks[1]) WITH Residual ---
    print("   -> Exporting Layer 3 (Bottleneck Block 1 with Residual)")
    btn_res = net.blocks[1]
    btn_res_input = x.clone()
    
    with torch.no_grad():
        x = export_conv_block("layer3_pw1", btn_res.conv[0], btn_res.conv[1], btn_res.conv[2], x)
        x = export_conv_block("layer3_dw", btn_res.conv[3], btn_res.conv[4], btn_res.conv[5], x)
        x = export_conv_block("layer3_pw2", btn_res.conv[6], btn_res.conv[7], None, x)
        
        dump_tensor(f"{GOLDEN_DIR}/layer3_residual_in.txt", btn_res_input)
        x = x + btn_res_input
        dump_tensor(f"{GOLDEN_DIR}/layer3_residual_out_pytorch.txt", x)
    
    
    print("3. Executing C Golden Model to verify MAC arithmetic...")
    if not os.path.exists(C_MODEL_EXE):
        print(f"Error: {C_MODEL_EXE} not found! Did you compile it?")
        return
        
    try:
        subprocess.run([C_MODEL_EXE], check=True)
    except subprocess.CalledProcessError:
        print("C model execution failed.")
        return

    print("4. Verifying C vs PyTorch Outputs...")
    layers_to_check = [
        ("Layer 0 (Std Conv)", "layer0_out_pytorch.txt", "layer0_out_c.txt"),
        ("Layer 1 (DW Conv)", "layer1_out_pytorch.txt", "layer1_out_c.txt"),
        ("Layer 2 PW1", "layer2_pw1_out_pytorch.txt", "layer2_pw1_out_c.txt"),
        ("Layer 2 DW", "layer2_dw_out_pytorch.txt", "layer2_dw_out_c.txt"),
        ("Layer 2 PW2", "layer2_pw2_out_pytorch.txt", "layer2_pw2_out_c.txt"),
        ("Layer 3 PW1", "layer3_pw1_out_pytorch.txt", "layer3_pw1_out_c.txt"),
        ("Layer 3 DW", "layer3_dw_out_pytorch.txt", "layer3_dw_out_c.txt"),
        ("Layer 3 PW2", "layer3_pw2_out_pytorch.txt", "layer3_pw2_out_c.txt"),
        ("Layer 3 Residual", "layer3_residual_out_pytorch.txt", "layer3_residual_out_c.txt")
    ]
    
    success = True
    for name, py_file, c_file in layers_to_check:
        try:
            out_py = np.loadtxt(f"{GOLDEN_DIR}/{py_file}", dtype=np.float32)
            out_c = np.loadtxt(f"{GOLDEN_DIR}/{c_file}", dtype=np.float32)
            diff = np.max(np.abs(out_py - out_c))
            if diff < 1e-4:
                print(f"[PASS] {name}: Max Error = {diff}")
            else:
                print(f"[FAIL] {name}: Max Error = {diff} > 1e-4")
                success = False
        except Exception as e:
            print(f"[ERROR] Could not verify {name}: {e}")
            success = False

    print("====================================")
    if success:
        print("OVERALL SUCCESS: All C Model blocks match PyTorch correctly!")
    else:
        print("WARNING: Some blocks failed verification.")
    print("====================================")


if __name__ == "__main__":
    main()
