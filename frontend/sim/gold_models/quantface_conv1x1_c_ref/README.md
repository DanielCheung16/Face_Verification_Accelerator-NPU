# QuantFace Conv1x1 C Reference

This folder is a software-side checkpoint before RTL comparison.

Flow:
Prepare: chose the verified layers in `quantface_con1x1_slice/config.json`，then exporting the RTL data package:
python frontend/sim/gold_models/quantface_conv1x1_slice/export_quantface_conv1x1_hw.py

1. `gen_c_ref.py` loads the trained QuantFace model from `pretrained_models`, runs the configured layers, and exports C arrays plus the fixed-point parameters.
2. `quantface_conv1x1_ref.c` runs the same integer datapath intended for RTL:
   - weight: per-output-channel symmetric int8
   - activation: per-layer asymmetric int8
   - accumulator: int32
   - bias: int64 Q16, including activation zero-point correction and BN folding
   - residual: fixed-point scale alignment into the Q16 work domain
   - PReLU: per-output-channel multiplier with a common shift
   - requant: per-output-channel multiplier with a common shift
3. `dump_sram_hex.c` runs the C datapath and writes full-depth SRAM images:
   - `out/quantface_conv1x1_c_ao_init.hex`
   - `out/quantface_conv1x1_c_wgt_init.hex`
   - `out/quantface_conv1x1_c_golden.hex`
4. The C program reports:
   - C output vs Python fixed-point golden
   - C output vs true QuantFace quantized output

Run:

```bash
# use the relative path of the current folder
source ../../../../qface_env/bin/activate
python ../quantface_conv1x1_slice/export_quantface_conv1x1_hw.py
python gen_c_ref.py
make run
make dump
```

The C-vs-Python fixed-point comparison should be exact. The C-vs-QuantFace comparison measures the numerical gap between the hardware-friendly integer model and the original QuantFace floating/dequantized graph.

The top-level closed-loop testbench reads the C-generated SRAM images directly, so the RTL AO SRAM final output is compared against the C model output rather than a Python-produced golden file.
