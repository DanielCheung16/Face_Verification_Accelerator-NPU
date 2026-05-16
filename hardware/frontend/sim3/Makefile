# ============================================================
# Makefile for MobileFaceNet Frontend v3 Simulation (Xcelium)
#
# v3: 12×12 Output-Stationary Systolic Array
#
# Usage:
#   make sa_test   — Unit test for SA array (fast, no weights needed)
#   make hex       — Generate hex ROM files (same as sim2)
#   make top       — Run full RTL simulation (all 50 layers)
#   make diff      — Compare v3 layer_hex_v3/ vs v2 sim2/layer_hex/ (50 layers)
#   make clean     — Remove Xcelium artifacts
# ============================================================

SV3_DIR := ../sv3
SV1_DIR := ../sv

XFLAGS  := -sv -access +rwc -timescale 1ns/1ps -64bit
ENV_FILE := /vol/ece303/genus_tutorial/cadence.env
SHELL   := /bin/tcsh

# ── SA unit test (no hex files needed) ──────────────────────────────────────
sa_test:
	source $(ENV_FILE); xrun $(XFLAGS) \
	    $(SV3_DIR)/mfn_pe.sv \
	    $(SV3_DIR)/mfn_sa_12x12.sv \
	    mfn_sa_tb.sv

# ── Full top-level simulation ────────────────────────────────────────────────
V3_SRC := \
    $(SV3_DIR)/mfn_pe.sv \
    $(SV3_DIR)/mfn_sa_12x12.sv \
    $(SV3_DIR)/mfn_weight_rom_v3.sv \
    $(SV3_DIR)/mfn_act_buf.sv \
    $(SV3_DIR)/mfn_psum_sram.sv \
    $(SV3_DIR)/mfn_bias_rom.sv \
    $(SV3_DIR)/mfn_prelu_rom.sv \
    $(SV3_DIR)/mfn_layer_config_rom.sv \
    $(SV3_DIR)/mfn_activation.sv \
    $(SV3_DIR)/mfn_controller_v3.sv \
    $(SV3_DIR)/mfn_frontend_top_v3.sv

TOP_TB := mfn_frontend_top_v3_tb.sv

.PHONY: sa_test hex top top_gui diff clean

hex/weights.hex:
	@mkdir -p hex
	cd ../sim2 && python3 gen_hex.py
	cp ../sim2/hex/*.hex hex/
	@echo "hex files copied to sim3/hex/"

hex: hex/weights.hex

top: hex/weights.hex
	source $(ENV_FILE); xrun $(XFLAGS) $(V3_SRC) $(TOP_TB)

top_gui: hex/weights.hex
	source $(ENV_FILE); xrun $(XFLAGS) -gui $(V3_SRC) $(TOP_TB)

# Compare v3 layer outputs against v2.
# v2 stores each layer's outputs at a buffer-specific base offset (from layer_config[63:62]);
# v3 uses ping-pong and always writes from address 0.
# compare_layers.py decodes the offsets from hex/config.hex and does the aligned comparison.
diff:
	@python3 compare_layers.py

clean:
	rm -rf xcelium.d INCA_libs xrun.log xrun.history waves.shm *.key layer_hex_v3/
	@echo "Cleaned."
