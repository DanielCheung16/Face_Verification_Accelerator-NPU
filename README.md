# MobileFaceNet Hardware Reference Implementation

This directory contains the golden reference models (both Python and C) for the MobileFaceNet hardware accelerator project. It is designed to generate bit-true reference vectors and provide a fully decoupled C-based inference engine for SystemVerilog RTL verification.

## Directory Structure

- `python/`: Contains PyTorch model definitions, TFRecord dataset extraction scripts, and golden weight exporters.
- `c_model/`: Contains the pure C implementation of the MobileFaceNet architecture, optimized for hardware mapping (Ping-Pong buffering, flattened NCHW memory layout).
- `src/`: Stores the PyTorch checkpoint (`068.ckpt`), sample images, and TFRecord dataset.

> [!IMPORTANT]
> **Required Downloads**
> The raw weights and dataset files are too large for version control. Please download them manually:
> 1. **Model Weights (`068.ckpt`)**: Download from [MobileFaceNet_Pytorch/model/best](https://github.com/Xiaoccer/MobileFaceNet_Pytorch/tree/master/model/best)
> 2. **TFRecord Dataset**: Download from [Kaggle: MobileFaceNet Dataset](https://www.kaggle.com/code/jasonhcwong/mobilefacenet/input)
> 
> 🛑 **Action Required**: After downloading, you MUST place both files inside the [`Project/software/src`](./software/src) directory before running any Python extraction scripts.
- `golden/`: (Auto-generated) Contains block-by-block text files for isolated RTL module testing.
- `golden_weights/`: (Auto-generated) Contains 150+ fused parameter text files for end-to-end inference.

## Prerequisites

1. **Python Environment**:
   It is recommended to use the provided virtual environment to ensure all dependencies (PyTorch, TensorFlow for TFRecords) are met.
   ```bash
   cd python
   source .venv/bin/activate
   # Ensure dependencies are installed: pip install torch torchvision pillow numpy tensorflow
   ```

2. **C Compiler**:
   Any standard `gcc` compiler will work. The C code is written in standard C without any external math libraries.

## Quick Start (Full Inference Verification)

To verify that the completely independent C model mathematically matches the PyTorch model (Cosine Similarity Check):

1. **Export the entire fused network weights**:
   ```bash
   cd python
   python3 export_full_model.py
   ```
   *(This extracts and fuses all BatchNorms into Convolutions, saving them to `../golden_weights/`)*

2. **Compile the C Inference Engine**:
   ```bash
   cd ../c_model
   make
   ```
   *(This builds `c_golden_model` for unit testing and `c_inference_model` for full network inference)*

3. **Run the End-to-End Similarity Test**:
   ```bash
   cd ../python
   python3 compare_similarity.py
   ```
   *(This runs the test images through both PyTorch and the C Engine and calculates the Max Absolute Error and Cosine Similarity)*

## Documentation

For a detailed explanation of the architecture, the difference between the testing models (`c_golden_model` vs `c_inference_model`), and how to map this reference design to RTL, please read:
- **[note.md](note.md)** - The primary developer notes and verification strategies.

## TODOs / Next Steps

- [ ] **Fixed-Point Quantization (INT8/INT16)**: The current C model uses `Float32` to guarantee exact mathematical alignment with PyTorch. The next immediate step is to refactor `tensor.c` and Python exporters to support low-precision integer quantization to reflect the actual hardware datapaths.
- [ ] **RTL Unit Development**: Implement SystemVerilog `MAC Arrays` and `Line Buffers` utilizing the block-by-block `golden/` text files for modular testbench debugging.
- [ ] **System-Level RTL Integration**: Wire all hardware modules together with a global finite state machine (FSM) and memory controller.
- [ ] **End-to-End RTL Verification**: Verify the entire integrated SystemVerilog wrapper against `c_inference_model` 128D embeddings and similarity calculations.
