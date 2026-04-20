import torch
import numpy as np
from model import MobileFacenet

def run_inference():
    """
    Inference script to generate golden vectors for the RTL simulator.
    This helps in step '3. C Reference Model' from the CE492 proposal.
    """
    device = torch.device("cpu") # Force CPU for deterministic golden vector generation
    
    # 1. Load Model
    net = MobileFacenet()
    net.eval()
    
    # Optional: Load pretrained weights
    try:
        net.load_state_dict(torch.load('mobilefacenet_dummy.pth', map_location=device))
        print("Loaded weights from mobilefacenet_dummy.pth")
    except FileNotFoundError:
        print("No weights found, using randomly initialized weights.")
        
    # 2. Prepare Deterministic Input
    # Useful for C-model and RTL verification
    np.random.seed(42)
    dummy_input_np = np.random.randn(1, 3, 112, 96).astype(np.float32)
    dummy_input = torch.tensor(dummy_input_np)
    
    # 3. Forward Pass
    with torch.no_grad():
        output = net(dummy_input)
        
    print("Inference completed. Output Shape:", output.shape)
    
    # 4. Dump Outputs for Verification (Golden file)
    # The output format can be tweaked to match what the 'C Baseline' expects
    with open("golden_input.txt", "w") as f:
        # Save flattened representation
        np.savetxt(f, dummy_input_np.flatten(), fmt="%.6f")
        
    with open("golden_output.txt", "w") as f:
        np.savetxt(f, output.numpy().flatten(), fmt="%.6f")
        
    print("Exported golden_input.txt and golden_output.txt")
    print("Note: Update this to dump intermediate layer activations if needed for C/RTL module comparison.")

if __name__ == "__main__":
    run_inference()
