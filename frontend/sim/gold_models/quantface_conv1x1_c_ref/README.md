# QuantFace Conv1x1 C Reference

This folder is a software-side checkpoint before RTL comparison.

Flow:

1. `gen_c_ref.py` loads the trained QuantFace model from `pretrained_models`, runs the configured layers, and exports C arrays plus the fixed-point parameters.
2. `quantface_conv1x1_ref.c` runs the same integer datapath intended for RTL:
   - weight: per-output-channel symmetric int8
   - activation: per-layer asymmetric int8
   - accumulator: int32
   - bias: int32, including activation zero-point correction and BN folding
   - residual: fixed-point scale alignment before the main requant
   - PReLU: per-output-channel multiplier with a common shift
   - requant: per-output-channel multiplier with a common shift
3. The C program reports:
   - C output vs Python fixed-point golden
   - C output vs true QuantFace quantized output

Run:

```bash
source ../../../../qface_env/bin/activate
python gen_c_ref.py
make run
```

The C-vs-Python fixed-point comparison should be exact. The C-vs-QuantFace comparison measures the numerical gap between the hardware-friendly integer model and the original QuantFace floating/dequantized graph.
