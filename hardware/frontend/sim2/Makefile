# ============================================================
# Makefile for MobileFaceNet Frontend v2 Simulation (Xcelium)
#
# v2 RTL: ../sv2/  (wide SRAM fetch + CLA adder + dual MAC)
# v1 RTL: ../sv/   (unchanged modules reused below)
#
# Usage:
#   make hex      — Generate hex ROM files (weights/bias/config/prelu/input)
#   make top      — Run RTL simulation (all 50 layers)
#   make top_gui  — Run RTL sim with Xcelium GUI (waveform debug)
#   make diff     — Compare RTL layer-hex output with v1 sim/
#   make gl       — Run GATE-LEVEL simulation (synthesised netlist)
#   make gl_gui   — Run gate-level sim with Xcelium GUI
#   make diff_gl  — Compare GL layer_hex_gl/ vs RTL layer_hex/ (50 layers)
#   make clean    — Remove Xcelium artifacts
# ============================================================

# SV1: unchanged modules (activation, mac, bias/prelu/config rom)
# SV2: v2 modified modules (cla40, sliding_window, addr_gen, weight_rom, ctrl, top)
SV1_DIR := ../sv
SV2_DIR := ../sv2

XFLAGS   := -sv -access +rwc -timescale 1ns/1ps -64bit
# +notimingchecks disables $setuphold/$recrem checks in stdcell models
# (zero-delay functional sim — no SDF loaded anyway)
GL_FLAGS := $(XFLAGS) +notimingchecks
ENV_FILE := /vol/ece303/genus_tutorial/cadence.env
SHELL    := /bin/tcsh

# v2 RTL sources: sv2 overrides, then sv1 unchanged modules
V2_SRC := $(SV2_DIR)/mfn_cla40.sv \
           $(SV2_DIR)/mfn_sliding_window.sv \
           $(SV2_DIR)/mfn_addr_gen.sv \
           $(SV2_DIR)/mfn_weight_rom.sv \
           $(SV2_DIR)/mfn_psum_sram.sv \
           $(SV2_DIR)/mfn_controller.sv \
           $(SV2_DIR)/mfn_frontend_top.sv \
           $(SV1_DIR)/mfn_mac_array.sv \
           $(SV1_DIR)/mfn_activation.sv \
           $(SV1_DIR)/mfn_bias_rom.sv \
           $(SV1_DIR)/mfn_prelu_rom.sv \
           $(SV1_DIR)/mfn_layer_config_rom.sv

TOP_TB  := mfn_frontend_top_v2_tb.sv

# Gate-level simulation sources
STDCELL_V  := /vol/ece303/genus_tutorial/NangateOpenCellLibrary.v
NETLIST    := ../syn/mfn_frontend_top_v2_syn.v
STRIP_PY   := strip_stubs.py
STRIPPED   := stripped_netlist.v
BEH_OVRD   := netlist_beh.sv
GL_TB      := mfn_frontend_top_v2_gl_tb.sv

# -------------------------------------------------------
.PHONY: hex top top_gui diff gl gl_gui diff_gl clean

hex:
	python3 gen_hex.py
	@echo "hex files written to hex/"

top: hex/weights.hex
	source $(ENV_FILE); xrun $(XFLAGS) $(V2_SRC) $(TOP_TB)

top_gui: hex/weights.hex
	source $(ENV_FILE); xrun $(XFLAGS) -gui $(V2_SRC) $(TOP_TB)

# Compare v2 layer outputs against v1 (should be identical if RTL is correct)
diff:
	@echo "=== Comparing v2 layer_hex/ vs v1 sim/layer_hex/ ==="
	@python3 -c "\
import subprocess; \
results = [subprocess.call(['diff','-q','layer_hex/rtl_out_layer%d.hex'%i,'../sim/layer_hex/rtl_out_layer%d.hex'%i],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for i in range(50)]; \
[print('  Layer %d: %s' % (i, 'MATCH' if r==0 else 'MISMATCH <<<')) for i,r in enumerate(results)]; \
print('All 50 layers MATCH' if all(r==0 for r in results) else 'MISMATCH found')"

# ── Gate-level simulation ────────────────────────────────────────────────────
# 1. strip_stubs.py removes the empty module defs from the netlist so that
#    netlist_beh.sv can provide behavioral implementations without conflict.
# 2. Compile order: stdcell → beh overrides → stripped netlist → GL testbench
$(STRIPPED): $(NETLIST) $(STRIP_PY)
	python3.8 $(STRIP_PY) $(NETLIST) $(STRIPPED)

gl: hex/weights.hex $(STRIPPED)
	@mkdir -p layer_hex_gl
	source $(ENV_FILE); xrun $(GL_FLAGS) \
	    $(STDCELL_V) $(BEH_OVRD) $(STRIPPED) $(GL_TB)

gl_gui: hex/weights.hex $(STRIPPED)
	@mkdir -p layer_hex_gl
	source $(ENV_FILE); xrun $(GL_FLAGS) -gui \
	    $(STDCELL_V) $(BEH_OVRD) $(STRIPPED) $(GL_TB)

# Compare GL layer_hex_gl/ vs RTL layer_hex/ for all 50 layers
diff_gl:
	@echo "=== Comparing GL layer_hex_gl/ vs RTL layer_hex/ ==="
	@python3 -c "\
import subprocess; \
results = [subprocess.call(['diff','-q','layer_hex_gl/rtl_out_layer%d.hex'%i,'layer_hex/rtl_out_layer%d.hex'%i],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for i in range(50)]; \
[print('  Layer %d: %s' % (i, 'MATCH' if r==0 else 'MISMATCH <<<')) for i,r in enumerate(results)]; \
print('All 50 layers MATCH (GL == RTL)' if all(r==0 for r in results) else 'MISMATCH found — check layer above')"

clean:
	rm -rf xcelium.d INCA_libs xrun.log xrun.history waves.shm *.key \
	       $(STRIPPED) layer_hex_gl/
	@echo "Cleaned."
