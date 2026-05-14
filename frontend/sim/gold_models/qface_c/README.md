# qface_c

Whole-model C reference for the current hardware quantization spec.

The goal is not bit-exact QuantFace. The goal is to quantify the error of the
hardware-friendly model:

- weight: per-output-channel symmetric int8
- activation: per-layer asymmetric int8
- accumulator: int32
- bias: includes activation zero-point correction and BN folding
- PReLU: common shift per layer, multiplier per output channel
- requant: common shift per layer for this first version

Generate and run the full-model C reference:

```bash
source ../../../../qface_env/bin/activate
python gen_qface_c.py
make run
```

`gen_qface_c.py` writes `generated/qface_params.h` and
`generated/qface_params.c`. The C model exposes callable APIs in
`include/qface_model.h`, so RTL tooling can call the reference instead of
parsing a stand-alone program.

Generate a continuous block range instead of the full model:

```bash
python gen_qface_c.py --list-blocks
python gen_qface_c.py --start-block conv_23 --end-block conv_23
python gen_qface_c.py --start-block conv_3_0 --end-block conv_3_0
make run
```

For a block range ending before `embedding`, the C program compares int8 NHWC
output against the Python HW-spec golden output. For the full model, it compares
the final float embedding against the PyTorch QuantFace embedding.

Evaluate an InsightFace verification bin:

```bash
python eval_bin.py --bin ../../../../datasets/faces_eval/lfw.bin --batch-size 32 --no-flip
python eval_bin.py --bin ../../../../datasets/faces_eval/agedb_30.bin --batch-size 32 --no-flip
```
