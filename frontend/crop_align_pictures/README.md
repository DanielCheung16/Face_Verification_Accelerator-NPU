# Image Input Flow for Full-System Verification

## 1. Generate Aligned 112x112 Pictures

Put raw face images in:

```text
frontend/crop_align_pictures/row_pictures/
```

Run the face alignment script:

```bash
# From the repository root
source qface_env/bin/activate

# Detect the face, align it with InsightFace landmarks, and save 112x112 images
python frontend/crop_align_pictures/align.py
```

The aligned images are written to:

```text
frontend/crop_align_pictures/112_112_pictures/
```

The script uses InsightFace to detect the largest face in each raw image, applies 5-point landmark alignment, and saves a `112x112` RGB face crop. These aligned images are the inputs used by the hardware/C-model verification flow.

You can also override the folders:

```bash
# Align images from a custom folder and write them to a custom output folder
python frontend/crop_align_pictures/align.py \
  --input frontend/crop_align_pictures/row_pictures \
  --output frontend/crop_align_pictures/112_112_pictures \
  --size 112
```

## 2. Export One Picture into the C/RTL Verification Inputs

`export_to_generated.py` takes one aligned image and updates:

```text
frontend/sim/gold_models/qface_c/generated/qface_params.c
```

Specifically, it replaces:

```c
const int8_t qf_input[37632] = { ... };
```

with the selected image tensor. The preprocessing is:

```text
image -> resize to 112x112 -> RGB -> normalize to [-1, 1] -> quantize to int8 -> flatten as HWC
```

Only the input tensor is changed. The model weights, quantization parameters, and layer schedule are still fixed unless the model/exporter is regenerated.

Example:

```bash
# From the repository root
source qface_env/bin/activate

# Replace qf_input[] with this aligned image
python frontend/crop_align_pictures/export_to_generated.py \
  frontend/crop_align_pictures/112_112_pictures/Mina1.jpg
```

After this step, `qface_params.c` contains the new input image. The next C dump will regenerate the A/O SRAM init and final golden output for this image.

## 3. Run Full RTL vs C Golden Verification

Run the full-system ModelSim flow:

```bash
# From the repository root
cd frontend/sim

# Build the C dump tool, generate hex files, compile RTL, run top.sv, and compare output
vsim -c -do top_full_model_hw_spec_c_ref.do
```

The `.do` file performs these steps:

```text
1. make -C gold_models/qface_c dump_system_2_2
2. run dump_system_2_2 generated/full_model_hw_spec 13
3. generate SRAM/config/parameter/golden hex files
4. compile RTL and testbench
5. load hex files into the top-level SRAM/ROM models
6. run top.sv
7. compare final 1x1x128 INT8 output with the C golden output
```

The generated files are placed under:

```text
frontend/sim/gold_models/qface_c/generated/full_model_hw_spec/
```

Important generated files:

```text
system_2_2_ao_init.hex      initial A/O SRAM image, including the selected input
system_2_2_wgt_init.hex     Weight SRAM image
quant_param_*.hex           quant_param_mem ROM images
layer_config.hex            layer_config_mem ROM image
system_2_2_golden.hex       expected final output SRAM contents
```

Complete command sequence:

```bash
# 1. Enter the repository and enable the Python environment
cd /home/jzh2008/nu_classes/ce392/Face_Verification_Accelerator-NPU
source qface_env/bin/activate

# 2. Generate aligned 112x112 face crops from raw images
python frontend/crop_align_pictures/align.py

# 3. Select one aligned image and export it into qface_params.c
python frontend/crop_align_pictures/export_to_generated.py \
  frontend/crop_align_pictures/112_112_pictures/Mina1.jpg

# 4. Run full RTL top verification against the C HW-spec golden model
cd frontend/sim
vsim -c -do top_full_model_hw_spec_c_ref.do
```

Expected pass message:

```text
[TB] system verification profile=13 PASSED words=8
```
