import argparse
import os
import torch
import tensorflow as tf
from PIL import Image
import io
import numpy as np
import subprocess
from model import MobileFacenet
from inference import preprocess_image
from tfrecord_same_person import generate_test_pairs

# === CONFIGURATION PATHS ===
TFRECORD_FILE = "../src/faces_ms1m_refine_v2_112x112-0-of-16.tfrecord"
CKPT_PATH = "../src/068.ckpt"
C_INFERENCE_EXE = "../c_model/c_inference_model"
C_FIXED_EXE = "../c_model_fixed/c_inference_model_fixed"
C_FIXED8_EXE = "../c_model_fixed8/c_inference_model_fixed8"
F_BITS = 10
SCALE = (1 << F_BITS)
F8_BITS = 6
SCALE8 = (1 << F8_BITS)
NUM_TEST_PAIRS = 10
TEST_IMG_DIR = "test_images"
ENGINE_CHOICES = ["pytorch", "c", "c_fixed", "c_fixed8"]
# ===========================


def _check_executable(exe_path):
    """Return (ok, reason). Tries a no-op run to catch Exec format errors."""
    if not os.path.exists(exe_path):
        return False, f"file not found: {exe_path}"
    try:
        r = subprocess.run([exe_path], capture_output=True, timeout=5)
        return True, ""
    except OSError as e:
        return False, str(e)
    except subprocess.TimeoutExpired:
        return True, ""


def extract_batch_indices(tfrecord_path, indices_set, output_dir):
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        
    all_exist = all(os.path.exists(f"{output_dir}/img_{idx}.jpg") for idx in indices_set)
    if all_exist:
        return
        
    print(f"Extracting {len(indices_set)} images from TFRecord...")
    dataset = tf.data.TFRecordDataset(tfrecord_path)
    extracted_count = 0
    target_count = len(indices_set)
    
    for i, raw_record in enumerate(dataset):
        if i in indices_set:
            example = tf.train.Example()
            example.ParseFromString(raw_record.numpy())
            
            if 'img_raw' in example.features.feature:
                img_bytes = example.features.feature['img_raw'].bytes_list.value[0]
            elif 'image' in example.features.feature:
                img_bytes = example.features.feature['image'].bytes_list.value[0]
            else:
                keys = example.features.feature.keys()
                img_key = list(keys)[0]
                img_bytes = example.features.feature[img_key].bytes_list.value[0]
                
            img = Image.open(io.BytesIO(img_bytes))
            img.save(f"{output_dir}/img_{i}.jpg")
            extracted_count += 1
            if extracted_count == target_count:
                break


def cosine_similarity(v1, v2):
    dot = np.dot(v1, v2)
    norm = np.linalg.norm(v1) * np.linalg.norm(v2)
    return dot / norm


class PyTorchEngine:
    name = "pytorch"
    label = "PyTorch"

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
            return None
        tensor, _ = preprocess_image(image_path)
        with torch.no_grad():
            output = self.net(tensor)
        return output.numpy().flatten()


class CModelEngine:
    name = "c"
    label = "C Float"

    def __init__(self, exe_path=C_INFERENCE_EXE):
        ok, reason = _check_executable(exe_path)
        if not ok:
            raise RuntimeError(f"[CModelEngine] Cannot run {exe_path}: {reason}")
        self.exe_path = exe_path
        print(f"[CModelEngine] Initialized with {self.exe_path}")

    def get_embedding(self, image_path):
        if not os.path.exists(image_path):
            return None
        _, input_np = preprocess_image(image_path)
        tmp_in, tmp_out = "tmp_in.txt", "tmp_out.txt"
        with open(tmp_in, "w") as f:
            np.savetxt(f, input_np.flatten(), fmt="%.6f")
        result = subprocess.run([self.exe_path, tmp_in, tmp_out], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[CModelEngine] CRASH: {result.stdout}\n{result.stderr}")
            raise subprocess.CalledProcessError(result.returncode, result.args)
        emb = np.loadtxt(tmp_out, dtype=np.float32)
        for f in [tmp_in, tmp_out]:
            if os.path.exists(f): os.remove(f)
        return emb


class CFixedModelEngine:
    name = "c_fixed"
    label = "C INT16"

    def __init__(self, exe_path=C_FIXED_EXE):
        ok, reason = _check_executable(exe_path)
        if not ok:
            raise RuntimeError(f"[CFixedModelEngine] Cannot run {exe_path}: {reason}")
        self.exe_path = exe_path
        print(f"[CFixedModelEngine] Initialized with {self.exe_path}")

    def get_embedding(self, image_path):
        if not os.path.exists(image_path):
            return None
        _, input_np = preprocess_image(image_path)
        input_q16 = np.clip(np.round(input_np * SCALE), -32768, 32767).astype(np.int16)
        tmp_in, tmp_out = "tmp_in_fixed.txt", "tmp_out_fixed.txt"
        with open(tmp_in, "w") as f:
            np.savetxt(f, input_q16.flatten(), fmt="%d")
        result = subprocess.run([self.exe_path, tmp_in, tmp_out], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[CFixedModelEngine] CRASH: {result.stdout}\n{result.stderr}")
            raise subprocess.CalledProcessError(result.returncode, result.args)
        emb = np.loadtxt(tmp_out, dtype=np.float32)
        for f in [tmp_in, tmp_out]:
            if os.path.exists(f): os.remove(f)
        return emb


class CFixed8ModelEngine:
    name = "c_fixed8"
    label = "C INT8"

    def __init__(self, exe_path=C_FIXED8_EXE):
        ok, reason = _check_executable(exe_path)
        if not ok:
            raise RuntimeError(f"[CFixed8ModelEngine] Cannot run {exe_path}: {reason}")
        self.exe_path = exe_path
        print(f"[CFixed8ModelEngine] Initialized with {self.exe_path}")

    def get_embedding(self, image_path):
        if not os.path.exists(image_path):
            return None
        _, input_np = preprocess_image(image_path)
        input_q8 = np.clip(np.round(input_np * SCALE8), -128, 127).astype(np.int8)
        tmp_in, tmp_out = "tmp_in_fixed8.txt", "tmp_out_fixed8.txt"
        with open(tmp_in, "w") as f:
            np.savetxt(f, input_q8.flatten(), fmt="%d")
        result = subprocess.run([self.exe_path, tmp_in, tmp_out], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[CFixed8ModelEngine] CRASH: {result.stdout}\n{result.stderr}")
            raise subprocess.CalledProcessError(result.returncode, result.args)
        emb = np.loadtxt(tmp_out, dtype=np.float32)
        for f in [tmp_in, tmp_out]:
            if os.path.exists(f): os.remove(f)
        return emb


ALL_ENGINE_CLASSES = {
    "pytorch":  PyTorchEngine,
    "c":        CModelEngine,
    "c_fixed":  CFixedModelEngine,
    "c_fixed8": CFixed8ModelEngine,
}


def build_engines(selected):
    engines = []
    for key in selected:
        cls = ALL_ENGINE_CLASSES[key]
        try:
            engines.append(cls())
        except Exception as e:
            print(f"[SKIP] {cls.__name__}: {e}")
    if not engines:
        raise SystemExit("No engines available. Exiting.")
    return engines


class SimilarityTestSuite:
    def __init__(self, engines):
        self.engines = engines
        self.labels = [e.label for e in engines]
        self.results = []

    def run_pair(self, idx1, idx2, pair_type):
        img1 = f"{TEST_IMG_DIR}/img_{idx1}.jpg"
        img2 = f"{TEST_IMG_DIR}/img_{idx2}.jpg"

        embs1 = [eng.get_embedding(img1) for eng in self.engines]
        embs2 = [eng.get_embedding(img2) for eng in self.engines]

        if any(e is None for e in embs1 + embs2):
            print(f"Skipping pair [{idx1}, {idx2}] due to missing embeddings.")
            return

        sims = {eng.name: cosine_similarity(e1, e2)
                for eng, e1, e2 in zip(self.engines, embs1, embs2)}

        self.results.append({'type': pair_type, 'id': f"[{idx1:4d}, {idx2:4d}]", **sims})

    def print_summary(self):
        names = [e.name for e in self.engines]
        ref = names[0]  # first engine is the reference for diff columns

        col_w = 9
        header = f"{'Type':<10} | {'Indices':<14}"
        for lbl in self.labels:
            header += f" | {lbl:<{col_w}}"
        for n in names[1:]:
            header += f" | vs {ref[:4]:<16}"
        print(f"\n{'=' * len(header)}\n{header}\n{'-' * len(header)}")

        for r in self.results:
            typ = "Positive" if r['type'] == "same" else "Negative"
            row = f"{typ:<10} | {r['id']:<14}"
            for n in names:
                row += f" | {r[n]:>{col_w}.4f}"
            for n in names[1:]:
                diff = abs(r[ref] - r[n])
                status = "(OK) " if diff < 0.05 else "(WARN)"
                row += f" | {diff:.6f} {status}      "
            print(row)
        print("=" * len(header) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(
        description="MobileFaceNet similarity test suite",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog=(
            "examples:\n"
            "  python3 compare_similarity.py                        # auto-detect all\n"
            "  python3 compare_similarity.py --engines pytorch      # PyTorch only\n"
            "  python3 compare_similarity.py --engines c c_fixed    # two C models\n"
            "  python3 compare_similarity.py -n 20                  # 20 pairs each\n"
        )
    )
    parser.add_argument(
        "--engines", nargs="+", choices=ENGINE_CHOICES, default=ENGINE_CHOICES,
        metavar="ENGINE",
        help=f"engines to run (default: all). choices: {ENGINE_CHOICES}"
    )
    parser.add_argument("-n", "--num-pairs", type=int, default=NUM_TEST_PAIRS,
                        help=f"number of same/diff pairs (default: {NUM_TEST_PAIRS})")
    return parser.parse_args()


def main():
    args = parse_args()

    print("Generating Test Pairs...")
    same_pairs, diff_pairs, all_indices = generate_test_pairs(TFRECORD_FILE, args.num_pairs)
    extract_batch_indices(TFRECORD_FILE, all_indices, TEST_IMG_DIR)

    print("\n--- Initializing Inference Engines ---")
    engines = build_engines(args.engines)
    active = [e.label for e in engines]
    print(f"Active engines: {active}\n")

    suite = SimilarityTestSuite(engines)

    print(f"Running {len(same_pairs)} Positive Pairs (Same Person)...")
    for p1, p2 in same_pairs:
        suite.run_pair(p1, p2, "same")

    print(f"\nRunning {len(diff_pairs)} Negative Pairs (Different People)...")
    for p1, p2 in diff_pairs:
        suite.run_pair(p1, p2, "diff")

    suite.print_summary()


if __name__ == "__main__":
    main()
