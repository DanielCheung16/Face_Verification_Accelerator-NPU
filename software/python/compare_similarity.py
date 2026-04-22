import os
import torch
import tensorflow as tf
from PIL import Image
import io
import numpy as np
import subprocess
from model import MobileFacenet
from inference import preprocess_image

# === CONFIGURATION PATHS ===
SAME_PERSON_INDICES = [381, 480]
TFRECORD_FILE = "../src/faces_ms1m_refine_v2_112x112-0-of-16.tfrecord"
CKPT_PATH = "../src/068.ckpt"
IMG1_PATH = "../src/same_person_1.jpg"
IMG2_PATH = "../src/same_person_2.jpg"
DIFF_PATH = "../src/tfrecord_samples/sample_000_label_904.jpg"
C_INFERENCE_EXE = "../c_model/c_inference_model"
# ===========================


def extract_specific_indices(tfrecord_path, indices):
    """
    Extracts images at specific indices from TFRecord if they don't exist yet.
    """
    dataset = tf.data.TFRecordDataset(tfrecord_path)
    extracted = {}
    
    for i, record in enumerate(dataset):
        if i in indices:
            example = tf.train.Example()
            example.ParseFromString(record.numpy())
            
            img_string = example.features.feature['img_raw'].bytes_list.value[0]
            img = Image.open(io.BytesIO(img_string))
            extracted[i] = img
            
        if len(extracted) == len(indices):
            break
            
    return extracted

def cosine_similarity(v1, v2):
    dot = np.dot(v1, v2)
    norm = np.linalg.norm(v1) * np.linalg.norm(v2)
    return dot / norm


class PyTorchEngine:
    def __init__(self, ckpt_path=CKPT_PATH):
        print("[PyTorchEngine] Loading model weights...")
        self.device = torch.device("cpu")
        self.net = MobileFacenet()
        self.net.eval()
        
        try:
            checkpoint = torch.load(ckpt_path, map_location=self.device)
            if 'net_state_dict' in checkpoint:
                state_dict = checkpoint['net_state_dict']
                new_state_dict = { (k[7:] if k.startswith('module.') else k): v for k, v in state_dict.items() }
                self.net.load_state_dict(new_state_dict)
            else:
                self.net.load_state_dict(checkpoint)
        except Exception as e:
            print(f"[PyTorchEngine] Warning: Could not load weights: {e}")
            
    def get_embedding(self, image_path):
        if not os.path.exists(image_path):
            print(f"[PyTorchEngine] File not found: {image_path}")
            return None
        tensor, _ = preprocess_image(image_path)
        with torch.no_grad():
            output = self.net(tensor)
        return output.numpy().flatten()


class CModelEngine:
    def __init__(self, exe_path=C_INFERENCE_EXE):
        self.exe_path = exe_path
        if not os.path.exists(self.exe_path):
            raise FileNotFoundError(f"C Executable not found at {self.exe_path}. Please make it first.")
        print(f"[CModelEngine] Initialized with {self.exe_path}")
            
    def get_embedding(self, image_path):
        if not os.path.exists(image_path):
            print(f"[CModelEngine] File not found: {image_path}")
            return None
            
        _, input_np = preprocess_image(image_path)
        
        tmp_in = "tmp_in.txt"
        tmp_out = "tmp_out.txt"
        
        with open(tmp_in, "w") as f:
            np.savetxt(f, input_np.flatten(), fmt="%.6f")
            
        try:
            subprocess.run([self.exe_path, tmp_in, tmp_out], check=True, stdout=subprocess.DEVNULL)
            emb = np.loadtxt(tmp_out, dtype=np.float32)
        except Exception as e:
            print(f"[CModelEngine] Error: {e}")
            emb = None
            
        for f in [tmp_in, tmp_out]:
            if os.path.exists(f): os.remove(f)
            
        return emb


def main():
    # 1. Ensure test images are extracted
    if not (os.path.exists(IMG1_PATH) and os.path.exists(IMG2_PATH)):
        print(f"Extracting test images from {TFRECORD_FILE}...")
        images = extract_specific_indices(TFRECORD_FILE, SAME_PERSON_INDICES)
        if len(images) == 2:
            images[SAME_PERSON_INDICES[0]].save(IMG1_PATH)
            images[SAME_PERSON_INDICES[1]].save(IMG2_PATH)
            print(f"Saved {IMG1_PATH} and {IMG2_PATH}")
        else:
            print("Failed to extract images. Exiting.")
            return

    # 2. Instantiate both inference engines
    print("\n--- Initializing Inference Engines ---")
    pytorch_engine = PyTorchEngine()
    try:
        c_engine = CModelEngine()
    except FileNotFoundError as e:
        print(e)
        return

    # 3. Test 1: Same Person Comparison
    print("\n====================================")
    print("Test 1: Same Person Comparison")
    print(f"Images: {IMG1_PATH} vs {IMG2_PATH}")
    print("====================================")
    
    py_emb1 = pytorch_engine.get_embedding(IMG1_PATH)
    py_emb2 = pytorch_engine.get_embedding(IMG2_PATH)
    c_emb1  = c_engine.get_embedding(IMG1_PATH)
    c_emb2  = c_engine.get_embedding(IMG2_PATH)
    
    if all(v is not None for v in [py_emb1, py_emb2, c_emb1, c_emb2]):
        py_sim = cosine_similarity(py_emb1, py_emb2)
        c_sim  = cosine_similarity(c_emb1, c_emb2)
        print(f"[PyTorch] Cosine Similarity: {py_sim:.4f}")
        print(f"[C Model] Cosine Similarity: {c_sim:.4f}")
        diff = abs(py_sim - c_sim)
        print(f"-> Similarity Diff: {diff:.6f} " + ("(PASS)" if diff < 1e-3 else "(FAIL)"))

    # 4. Test 2: Different People Comparison
    print("\n====================================")
    print("Test 2: Different People Comparison")
    print(f"Images: {IMG1_PATH} vs {DIFF_PATH}")
    print("====================================")
    
    py_emb3 = pytorch_engine.get_embedding(DIFF_PATH)
    c_emb3  = c_engine.get_embedding(DIFF_PATH)
    
    if all(v is not None for v in [py_emb1, py_emb3, c_emb1, c_emb3]):
        py_sim_diff = cosine_similarity(py_emb1, py_emb3)
        c_sim_diff  = cosine_similarity(c_emb1, c_emb3)
        print(f"[PyTorch] Cosine Similarity: {py_sim_diff:.4f}")
        print(f"[C Model] Cosine Similarity: {c_sim_diff:.4f}")
        diff = abs(py_sim_diff - c_sim_diff)
        print(f"-> Similarity Diff: {diff:.6f} " + ("(PASS)" if diff < 1e-3 else "(FAIL)"))

    print("\nVerification Complete.")


if __name__ == "__main__":
    main()
