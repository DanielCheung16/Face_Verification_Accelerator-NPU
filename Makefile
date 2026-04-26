PYTHON:= $(PWD)/qface_env/bin/python

# Check if the pretrained model works
dummy_check: 
	$(PYTHON) scripts/QuantFace/check_mobilefacenet.py

# Export layer-by-layer shapes and parameter metadata for NPU design
export_mobilefacenet_w8a8_layers:
	$(PYTHON) scripts/QuantFace/export_mobilefacenet_layer_table.py
