.PHONY: all venv clean run-inference run-tfrecord

VENV := .venv
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip

all: venv

# Create virtual environment and install dependencies if requirements.txt changes
venv: $(VENV)/touchfile

$(VENV)/touchfile: requirements.txt
	@echo "Checking virtual environment..."
	@test -d $(VENV) || python3 -m venv $(VENV)
	@echo "Upgrading pip..."
	@$(PIP) install --upgrade pip
	@echo "Installing requirements..."
	@$(PIP) install -r requirements.txt
	@touch $(VENV)/touchfile
	@echo "Virtual environment ready. You can now use '.venv/bin/python' or run 'source .venv/bin/activate'."

run-inference: venv
	$(PYTHON) inference.py $(ARGS)

run-tfrecord: venv
	$(PYTHON) read_tfrecord.py

clean:
	rm -rf $(VENV)
	rm -rf __pycache__
	rm -rf tfrecord_samples
	rm -f golden_*.txt
