import sys
import ctypes
import numpy as np
import torch
from PIL import Image
from pathlib import Path

# Add current path to import gen_qface_c
import gen_qface_c as gen

# Load the compiled shared library
LIB_PATH = Path(__file__).resolve().parent / "libqface.so"
if not LIB_PATH.exists():
    print(f"Error: {LIB_PATH} not found. Please compile it first with:")
    print("gcc -shared -fPIC -O2 -std=c99 -Wall -Iinclude -Igenerated src/qface_model.c generated/qface_params.c -o libqface.so -lm")
    sys.exit(1)

libqface = ctypes.CDLL(str(LIB_PATH))
# int qface_run_embedding(const int8_t *input_nhwc, float *embedding);
libqface.qface_run_embedding.argtypes = [ctypes.POINTER(ctypes.c_int8), ctypes.POINTER(ctypes.c_float)]
libqface.qface_run_embedding.restype = ctypes.c_int

def preprocess_image(image_path):
    """
    Standard Face Verification Preprocessing
    1. Resize to 112x112
    2. Convert to RGB numpy array
    3. Normalize to [-1.0, 1.0] via (x/255.0 - 0.5) / 0.5
    4. Convert to torch tensor with shape (1, 3, 112, 112)
    """
    img = Image.open(image_path).convert('RGB')
    img = img.resize((112, 112))
    img_np = np.asarray(img, dtype=np.float32)
    # HWC to CHW
    img_np = img_np.transpose((2, 0, 1))
    tensor = torch.from_numpy(img_np).unsqueeze(0)
    # Normalize
    tensor = ((tensor / 255.0) - 0.5) / 0.5
    return tensor

def get_embedding_from_c_model(image_path):
    # 1. Preprocess the image
    tensor = preprocess_image(image_path)
    
    # 2. Get hardware INT8 quantization (using the golden gen script)
    # quant_asym returns the quantized tensor, scale, and zero_point
    cur_q, _, _ = gen.quant_asym(tensor)
    
    # The C model expects NHWC format for the input image!
    # cur_q is currently (1, 3, 112, 112) -> convert to (1, 112, 112, 3)
    cur_q_nhwc = cur_q.permute(0, 2, 3, 1).contiguous()
    
    # Convert to int8 numpy array
    input_int8 = cur_q_nhwc.clamp(-128, 127).to(torch.int8).numpy()
    
    # 3. Prepare C pointers
    input_ptr = input_int8.ctypes.data_as(ctypes.POINTER(ctypes.c_int8))
    
    # Output embedding is 512-dim (or 128 depending on architecture), we allocate enough
    embedding_out = np.zeros(512, dtype=np.float32)
    emb_ptr = embedding_out.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
    
    # 4. Run the C Model
    res = libqface.qface_run_embedding(input_ptr, emb_ptr)
    if res != 0:
        raise RuntimeError("C model execution failed.")
        
    return embedding_out

def cosine_similarity(v1, v2):
    dot = np.dot(v1, v2)
    norm = np.linalg.norm(v1) * np.linalg.norm(v2)
    return dot / (norm + 1e-12)

def main():
    if len(sys.argv) != 3:
        print("Usage: python verify_demo.py <image1.jpg> <image2.jpg>")
        sys.exit(1)
        
    img1_path = sys.argv[1]
    img2_path = sys.argv[2]
    
    print(f"[{img1_path}] Extracting features via Hardware C Model...")
    emb1 = get_embedding_from_c_model(img1_path)
    
    print(f"[{img2_path}] Extracting features via Hardware C Model...")
    emb2 = get_embedding_from_c_model(img2_path)
    
    sim = cosine_similarity(emb1, emb2)
    print("=" * 50)
    print(f"Cosine Similarity: {sim:.4f}")
    
    THRESHOLD = 0.4  # Typical threshold
    if sim > THRESHOLD:
        print("Result: ✅ MATCH (Same Person)")
    else:
        print("Result: ❌ MISMATCH (Different People)")
    print("=" * 50)

if __name__ == "__main__":
    main()
