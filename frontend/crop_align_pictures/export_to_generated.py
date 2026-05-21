#!/usr/bin/env python3
import sys
import numpy as np
from PIL import Image
from pathlib import Path

# Setup paths
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
QFACE_PARAMS_C = REPO_ROOT / "frontend" / "sim" / "gold_models" / "qface_c" / "generated" / "qface_params.c"

def preprocess_and_quantize(image_path, in_scale, in_zp):
    """
    1. Load image and resize to 112x112
    2. Convert to float32 HWC array
    3. Normalize to [-1.0, 1.0] via (x/255.0 - 0.5) / 0.5
    4. Quantize to INT8 NHWC (HWC) format using NPU compiled scale and zero-point
    """
    img = Image.open(image_path).convert('RGB')
    img = img.resize((112, 112))
    img_np = np.asarray(img, dtype=np.float32)
    
    # Normalize to [-1.0, 1.0]
    normalized = ((img_np / 255.0) - 0.5) / 0.5
    
    # Quantize: q = round(x * scale - zp). zp is positive in python (zp = -in_zp)
    zp_val = -in_zp
    q_val = np.round(normalized * in_scale - zp_val).clip(-128, 127).astype(np.int8)
    
    # Return flattened HWC int8 array (length 37632)
    return q_val.flatten()

def update_qface_params_c(flat_array):
    if not QFACE_PARAMS_C.exists():
        print(f"Error: {QFACE_PARAMS_C} not found.")
        sys.exit(1)
        
    print(f"Reading {QFACE_PARAMS_C}...")
    content = QFACE_PARAMS_C.read_text(encoding="utf-8")
    
    # Find start of qf_input definition
    start_tag = "const int8_t qf_input[37632] = {"
    start_idx = content.find(start_tag)
    if start_idx == -1:
        print(f"Error: Could not find '{start_tag}' in qface_params.c")
        sys.exit(1)
        
    # Find start of next array definition (qf_weight)
    end_tag = "const int8_t qf_weight[976000] = {"
    end_idx = content.find(end_tag)
    if end_idx == -1:
        print(f"Error: Could not find '{end_tag}' in qface_params.c")
        sys.exit(1)
        
    # Format new qf_input array
    lines = [start_tag]
    for i in range(0, len(flat_array), 16):
        chunk = ", ".join(str(v) for v in flat_array[i:i+16])
        lines.append("    " + chunk + ("," if i + 16 < len(flat_array) else ""))
    lines.append("};")
    lines.append("")
    
    new_array_str = "\n".join(lines)
    
    # Replace old array with new array
    new_content = content[:start_idx] + new_array_str + content[end_idx:]
    
    print(f"Writing updated {QFACE_PARAMS_C}...")
    QFACE_PARAMS_C.write_text(new_content, encoding="utf-8")
    print("Successfully updated qf_input with the real image!")

def main():
    if len(sys.argv) < 2:
        print("Usage: python export_to_generated.py <image_path>")
        sys.exit(1)
        
    image_path = sys.argv[1]
    print(f"Exporting image to qface_params.c: {image_path}")
    
    # 1. Parse compiled input scale and zp from qface_params.c to be safe
    in_scale, in_zp = 31.1158485, -10  # default fallback
    try:
        content = QFACE_PARAMS_C.read_text(encoding="utf-8")
        for line in content.splitlines():
            if "{" in line and "}" in line and "112, 112, 3" in line:
                parts = line.strip().strip("{}").split(",")
                in_scale = float(parts[17].replace("f", "").strip())
                in_zp = int(parts[18].strip())
                break
    except Exception as e:
        print(f"Warning: Failed to parse scale/zp from C file ({e}). Using defaults.")
        
    print(f"Parsed C model first layer scale={in_scale:.6f}, zero-point={in_zp}")
    
    # 2. Preprocess, quantize and flatten
    flat_array = preprocess_and_quantize(image_path, in_scale, in_zp)
    
    # 3. Write to file
    update_qface_params_c(flat_array)

if __name__ == "__main__":
    main()
