import os
import glob

replacements = {
    "int16_t": "int8_t",
    "Tensor1D_16": "Tensor1D_8",
    "clamp_to_int16": "clamp_to_int8",
    "32767": "127",
    "-32768": "-128",
    "Q_FRAC_BITS 10": "Q_FRAC_BITS 6",
    "golden_weights_fixed": "golden_weights_fixed8",
    "create_tensor_1d_16": "create_tensor_1d_8",
    "free_tensor_1d_16": "free_tensor_1d_8",
    "load_tensor_1d_16": "load_tensor_1d_8",
    "c_inference_model_fixed": "c_inference_model_fixed8"
}

files = glob.glob("../c_model_fixed8/*.[ch]") + ["../c_model_fixed8/Makefile"]

for file in files:
    with open(file, "r") as f:
        content = f.read()
        
    for k, v in replacements.items():
        content = content.replace(k, v)
        
    with open(file, "w") as f:
        f.write(content)

print("Modification to INT8 complete!")
