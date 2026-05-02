PYTHON:= $(PWD)/qface_env/bin/python
MODEL_PATH:=$(PWD)/pretrained_models/quantface_mobilefacenet_w8a8_real

# Check if the pretrained model works
dummy_check: 
	$(PYTHON) scripts/QuantFace/check_mobilefacenet.py

# Export layer-by-layer shapes and parameter metadata for NPU design
export_mobilefacenet_w8a8_layers:
	$(PYTHON) scripts/QuantFace/export_mobilefacenet_layer_table.py

# Build the needed directory
.PHONY: init

init:
	mkdir -p $(MODEL_PATH)
	@printf "\n Please download mobilefacenet_w8a8_real from the link in QuantFace/README.md,\n"
	@printf "then put backbone.pt into: $(MODEL_PATH)\n"
