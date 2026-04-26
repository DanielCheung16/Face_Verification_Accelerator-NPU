PYTHON:= $(PWD)/qface_env/bin/python

# Check if the pretrained model works
dummy_check: 
	$(PYTHON) scripts/QuantFace/check_mobilefacenet.py