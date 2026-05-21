# ============================================================
# Makefile for MobileFaceNet Frontend v3 Simulation (Xcelium)
#
# v3: 12×12 Output-Stationary Systolic Array
#
# Usage:
#   make sa_test    — Unit test for SA array (fast, no weights needed)
#   make hex        — Generate hex ROM files (same as sim2)
#   make top        — Run full RTL simulation (all 50 layers)
#   make diff       — Compare v3 layer_hex_v3/ vs v2 sim2/layer_hex/ (50 layers)
#   make gl         — GL sim with Genus syn netlist     → layer_hex_gl_v3/
#   make gl_gui     — Same as `gl` but with Xcelium GUI
#   make diff_gl    — Compare layer_hex_gl_v3/   vs RTL layer_hex_v3/
#   make pnr        — GL sim with Innovus POST-ROUTE netlist → layer_hex_pnr_v3/
#   make pnr_gui    — Same as `pnr` but with Xcelium GUI
#   make diff_pnr   — Compare layer_hex_pnr_v3/  vs RTL layer_hex_v3/
#   make clean      — Remove Xcelium artifacts
# ============================================================

SV3_DIR := ../sv3
SV1_DIR := ../sv

XFLAGS  := -sv -access +rwc -timescale 1ns/1ps -64bit
# Force the testbench to be the simulation top — without this xrun picks the
# first un-instantiated module alphabetically (AND2_X4 from the cell lib).
GL_TOP  := -top worklib.mfn_frontend_top_v3_gl_tb
# +notimingchecks: zero-delay functional GL sim (no SDF loaded)
GL_FLAGS := $(XFLAGS) +notimingchecks
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
    $(SV3_DIR)/sram_act_buf_1rw0r0w_192_64_freepdk45.sv \
    $(SV3_DIR)/mfn_act_buf.sv \
    $(SV3_DIR)/mfn_psum_sram.sv \
    $(SV3_DIR)/mfn_bias_rom.sv \
    $(SV3_DIR)/mfn_prelu_rom.sv \
    $(SV3_DIR)/mfn_layer_config_rom.sv \
    $(SV3_DIR)/mfn_activation.sv \
    $(SV3_DIR)/mfn_controller_v3.sv \
    $(SV3_DIR)/mfn_frontend_top_v3.sv

TOP_TB := mfn_frontend_top_v3_tb.sv

# ── Gate-level simulation sources ────────────────────────────────────────────
STDCELL_V    := /vol/ece303/genus_tutorial/NangateOpenCellLibrary.v
SYN_NETLIST  := ../syn/mfn_frontend_top_v3_syn.v
PNR_NETLIST  := ../../backend/mfn_frontend_top_v3_final_nophy.v
STRIP_PY     := strip_stubs.py
SYN_STRIPPED := stripped_netlist_v3.v
PNR_STRIPPED := stripped_netlist_v3_pnr.v
BEH_OVRD     := netlist_beh_v3.sv
ACT_SRAM     := $(SV3_DIR)/sram_act_buf_1rw0r0w_192_64_freepdk45.sv
GL_TB        := mfn_frontend_top_v3_gl_tb.sv

.PHONY: sa_test hex top top_gui diff gl gl_gui diff_gl pnr pnr_gui diff_pnr clean

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

# ── Gate-level simulation ────────────────────────────────────────────────────
# strip_stubs.py removes the 4 empty ROM stub defs from the netlist (syn or
# post-route) so behavioral models in netlist_beh_v3.sv bind without
# redefinition errors.  Compile order:
#   stdcell lib → behavioral overrides → act_buf SRAM model
#   → stripped netlist → GL testbench (+dumpdir plusarg).
$(SYN_STRIPPED): $(SYN_NETLIST) $(STRIP_PY)
	python3.8 $(STRIP_PY) $(SYN_NETLIST) $(SYN_STRIPPED)

$(PNR_STRIPPED): $(PNR_NETLIST) $(STRIP_PY)
	python3.8 $(STRIP_PY) $(PNR_NETLIST) $(PNR_STRIPPED)

# ── Genus syn netlist GL sim ─────────────────────────────────────────────────
# `-xmlibdirname xcelium_gl.d` keeps this run's work library separate from
# `pnr` so the two can execute concurrently without xmlib lock contention.
gl: hex/weights.hex $(SYN_STRIPPED)
	@mkdir -p layer_hex_gl_v3
	source $(ENV_FILE); xrun $(GL_FLAGS) $(GL_TOP) -xmlibdirname xcelium_gl.d \
	    $(STDCELL_V) $(BEH_OVRD) $(ACT_SRAM) $(SYN_STRIPPED) $(GL_TB) \
	    +dumpdir=layer_hex_gl_v3

gl_gui: hex/weights.hex $(SYN_STRIPPED)
	@mkdir -p layer_hex_gl_v3
	source $(ENV_FILE); xrun $(GL_FLAGS) $(GL_TOP) -gui -xmlibdirname xcelium_gl.d \
	    $(STDCELL_V) $(BEH_OVRD) $(ACT_SRAM) $(SYN_STRIPPED) $(GL_TB) \
	    +dumpdir=layer_hex_gl_v3

diff_gl:
	@echo "=== Comparing GL layer_hex_gl_v3/ vs RTL layer_hex_v3/ ==="
	@python3 -c "\
import subprocess; \
r = [subprocess.call(['diff','-q','layer_hex_gl_v3/rtl_out_layer%d.hex'%i,'layer_hex_v3/rtl_out_layer%d.hex'%i],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for i in range(50)]; \
[print('  Layer %d: %s'%(i,'MATCH' if x==0 else 'MISMATCH <<<')) for i,x in enumerate(r)]; \
print('All 50 layers MATCH (GL == RTL)' if all(x==0 for x in r) else 'MISMATCH found')"

# ── Innovus post-route netlist GL sim ────────────────────────────────────────
# Same TB / behavioral models as `gl`, but bound against the post-route
# netlist (../../backend/mfn_frontend_top_v3_final_nophy.v).  Functional
# (+notimingchecks) verification only — for timing-annotated sim, load the
# SDF separately with $sdf_annotate (not enabled here).
pnr: hex/weights.hex $(PNR_STRIPPED)
	@mkdir -p layer_hex_pnr_v3
	source $(ENV_FILE); xrun $(GL_FLAGS) $(GL_TOP) -xmlibdirname xcelium_pnr.d \
	    $(STDCELL_V) $(BEH_OVRD) $(ACT_SRAM) $(PNR_STRIPPED) $(GL_TB) \
	    +dumpdir=layer_hex_pnr_v3

pnr_gui: hex/weights.hex $(PNR_STRIPPED)
	@mkdir -p layer_hex_pnr_v3
	source $(ENV_FILE); xrun $(GL_FLAGS) $(GL_TOP) -gui -xmlibdirname xcelium_pnr.d \
	    $(STDCELL_V) $(BEH_OVRD) $(ACT_SRAM) $(PNR_STRIPPED) $(GL_TB) \
	    +dumpdir=layer_hex_pnr_v3

diff_pnr:
	@echo "=== Comparing PNR layer_hex_pnr_v3/ vs RTL layer_hex_v3/ ==="
	@python3 -c "\
import subprocess; \
r = [subprocess.call(['diff','-q','layer_hex_pnr_v3/rtl_out_layer%d.hex'%i,'layer_hex_v3/rtl_out_layer%d.hex'%i],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for i in range(50)]; \
[print('  Layer %d: %s'%(i,'MATCH' if x==0 else 'MISMATCH <<<')) for i,x in enumerate(r)]; \
print('All 50 layers MATCH (PNR == RTL)' if all(x==0 for x in r) else 'MISMATCH found')"

clean:
	rm -rf xcelium.d xcelium_gl.d xcelium_pnr.d INCA_libs \
	       xrun.log xrun.history waves.shm *.key \
	       layer_hex_v3/ layer_hex_gl_v3/ layer_hex_pnr_v3/ \
	       $(SYN_STRIPPED) $(PNR_STRIPPED)
	@echo "Cleaned."
