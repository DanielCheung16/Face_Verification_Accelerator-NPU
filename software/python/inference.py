import torch
import numpy as np
import argparse
from PIL import Image
from model import MobileFacenet

# === CONFIGURATION PATHS ===
CKPT_PATH = "../src/068.ckpt"
GOLDEN_IN_TXT = "golden_input.txt"
GOLDEN_OUT_TXT = "golden_output.txt"
# ===========================


def preprocess_image(image_path):
    """
    Load an image, resize, normalize, and convert to tensor.
    """
    img = Image.open(image_path).convert('RGB')
    # Resize to Width=96, Height=112 (expected by conventional MobileFaceNet LFW crops)
    img = img.resize((96, 112))
    
    img_np = np.array(img, dtype=np.float32)
    # Standard normalization for face models: (img - 127.5) / 128.0
    img_np = (img_np - 127.5) / 128.0
    
    # HWC to CHW
    img_np = img_np.transpose((2, 0, 1))
    
    # Add batch dimension: (1, 3, 112, 96)
    input_np = np.expand_dims(img_np, axis=0)
    input_tensor = torch.tensor(input_np)
    
    return input_tensor, input_np

def run_inference(image_path=None):
    device = torch.device("cpu") # Force CPU for deterministic generation
    
    # 1. Load Model
    net = MobileFacenet()
    net.eval()
    
    try:
        ckpt_path = CKPT_PATH
        checkpoint = torch.load(ckpt_path, map_location=device)
        
        # Original MobileFaceNet_Pytorch repo saves the state dict inside 'net_state_dict' key
        if 'net_state_dict' in checkpoint:
            state_dict = checkpoint['net_state_dict']
            new_state_dict = {}
            for k, v in state_dict.items():
                name = k[7:] if k.startswith('module.') else k
                new_state_dict[name] = v
            net.load_state_dict(new_state_dict)
        else:
            net.load_state_dict(checkpoint)
            
        print(f"Successfully loaded weights from {ckpt_path}")
    except FileNotFoundError:
        print(f"No weights found at {ckpt_path}, using randomly initialized weights.")
        
    # 2. Prepare Input
    if image_path:
        print(f"Processing real image: {image_path}")
        input_tensor, input_np = preprocess_image(image_path)
    else:
        print("Processing deterministic dummy input...")
        np.random.seed(42)
        input_np = np.random.randn(1, 3, 112, 96).astype(np.float32)
        input_tensor = torch.tensor(input_np)
    
    # 3. Forward Pass
    with torch.no_grad():
        output = net(input_tensor)
        
    print("Inference completed. Output Shape:", output.shape)
    
    # 4. Dump Outputs for Verification (Golden file)
    with open(GOLDEN_IN_TXT, "w") as f:
        np.savetxt(f, input_np.flatten(), fmt="%.6f")
        
    with open(GOLDEN_OUT_TXT, "w") as f:
        np.savetxt(f, output.numpy().flatten(), fmt="%.6f")
        
    print(f"Exported {GOLDEN_IN_TXT} and {GOLDEN_OUT_TXT}")
    print("The 128-d embedding (golden_output.txt) can now be used for face comparison logic (e.g. Cosine Similarity) or Hardware verification.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run inference on MobileFaceNet")
    parser.add_argument("--image", type=str, default=None, help="Path to a user image. If not provided, runs dummy data.")
    args = parser.parse_args()
    
    run_inference(args.image)
