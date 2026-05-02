import torch
import sys
from pathlib import Path

# Go up two directories from the current script location to reach the project root directory
PROJECT_ROOT = Path(__file__).resolve().parents[2]

MODEL_PATH = PROJECT_ROOT / "pretrained_models" / "quantface_mobilefacenet_w8a8_real" / "backbone.pt"

sys.path.insert(0, str(PROJECT_ROOT / "QuantFace"))

def main():
    print("Project root:", PROJECT_ROOT)
    print("Model path:", MODEL_PATH)

    model = torch.load(MODEL_PATH, map_location="cpu")
    print("Model type:", type(model))

    model.eval()
    
    # x is the input images
    x = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        y = model(x)

    print("Input shape:", tuple(x.shape))

    if hasattr(y, "shape"):
        print("Output shape:", tuple(y.shape))
    else:
        print("Output type:", type(y))
        print("Output:", y)

    with open( str(PROJECT_ROOT / "network_parameters" / "mobilefacenet_w8a8_real"/"all.txt"), "w") as f:
        print("\nModel structure:\n", file=f)
        print(model, file=f)


if __name__ == "__main__":
    main()