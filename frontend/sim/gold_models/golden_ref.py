import numpy as np
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

def int_to_hex(value,width):
    mask= (1<<width)-1
    return f"{value&mask:0{width//4}x}"

def matmul (H, W):
    A = np.random.randint(-100, 100, size=(H, W), dtype=np.int8)
    B = np.random.randint(-100, 100, size=(H, W), dtype=np.int8)

    with open (BASE_DIR / "activation.hex", "w") as f:
        for i in range(H):
            for j in range(W):
                f.write(int_to_hex(A[i,j],8)+"\n")
        for x in A.flat:
            print(int_to_hex(x,8))

    with open (BASE_DIR / "weight.hex", "w") as f:
        for x in B.flat:
            f.write(int_to_hex(x,8)+"\n")

    C = A.astype(np.int32) @ B.astype(np.int32)

    with open (BASE_DIR / "golden.hex", "w") as f:
        for x in C.flat:
            f.write(int_to_hex(x,32)+"\n")

if __name__ == "__main__":
    matmul(4,4)
