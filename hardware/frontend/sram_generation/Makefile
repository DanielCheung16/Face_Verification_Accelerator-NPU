# ============================================================
# Makefile — OpenRAM SRAM Generation for MobileFaceNet v2/v3
#
# v2 SRAMs (psum accumulator, 40×512):
#   SRAM_A  sram_psum_a_1rw1r0w_40_512_freepdk45  (1RW+1R)
#   SRAM_B  sram_psum_b_1rw0r0w_40_512_freepdk45  (1RW)
#
# v3 SRAM (activation buffer, replaces 8192-FF array):
#   ACT_BUF sram_act_buf_1rw0r0w_16_512_freepdk45 (1RW, 16×512)
#           Estimated area: ~14 640 um² (vs 312 000 um² as FF array)
#
# Targets:
#   make gen          — Run OpenRAM for v2 psum SRAMs + v3 act_buf SRAM
#   make gen_psum     — Run OpenRAM for v2 psum SRAMs only
#   make gen_actbuf   — Run OpenRAM for v3 act_buf SRAM only
#   make lef          — Generate all synthetic LEF wrappers (no OpenRAM needed)
#   make install      — Copy .lib + .lef to syn/lib/ and backend/sram_lef/
#   make install_v3   — Install act_buf files for v3 P&R only
#   make clean        — Remove generated macro directories
#
# Prerequisites:
#   openram Python package must be importable.
#   If not found: export PYTHONPATH=/path/to/openram/compiler:$PYTHONPATH
#   (For synthetic LEF only: no OpenRAM needed, just python3.8)
# ============================================================

SHELL := /bin/tcsh

PYTHON    := python3.8
COMPILER  := sram_compiler.py

CFG_A     := freepdk45_sram_psum_a_40x512.py
CFG_B     := freepdk45_sram_psum_b_40x512.py
CFG_ACT   := freepdk45_sram_act_buf_16x512.py

NAME_A    := sram_psum_a_1rw1r0w_40_512_freepdk45
NAME_B    := sram_psum_b_1rw0r0w_40_512_freepdk45
NAME_ACT  := sram_act_buf_1rw0r0w_16_512_freepdk45

MACRO_A   := macro/$(NAME_A)
MACRO_B   := macro/$(NAME_B)
MACRO_ACT := macro/$(NAME_ACT)

# Install destinations
SYN_LIB_DIR := ../syn/lib
PNR_LEF_DIR := ../../backend/sram_lef

# -------------------------------------------------------
.PHONY: gen gen_psum gen_actbuf lef lef_psum lef_actbuf install install_v3 clean check

# ── Full generation (psum + act_buf) ──────────────────
gen: gen_psum gen_actbuf
	@echo "=== All SRAM macros generated ==="

gen_psum: $(MACRO_A)/$(NAME_A).lef $(MACRO_B)/$(NAME_B).lef
	@echo "=== psum SRAMs generated ==="

gen_actbuf: $(MACRO_ACT)/$(NAME_ACT).lef
	@echo "=== act_buf SRAM generated ==="

$(MACRO_A)/$(NAME_A).lef: $(CFG_A) $(COMPILER)
	@echo "--- Generating SRAM_A (1RW+1R, 40-bit x 512) ---"
	$(PYTHON) $(COMPILER) $(CFG_A)

$(MACRO_B)/$(NAME_B).lef: $(CFG_B) $(COMPILER)
	@echo "--- Generating SRAM_B (1RW, 40-bit x 512) ---"
	$(PYTHON) $(COMPILER) $(CFG_B)

$(MACRO_ACT)/$(NAME_ACT).lef: $(CFG_ACT) $(COMPILER)
	@echo "--- Generating act_buf SRAM (1RW, 16-bit x 512) ---"
	$(PYTHON) $(COMPILER) $(CFG_ACT)

# ── LEF generation (synthetic; no OpenRAM required) ───
# gen_act_buf_lef.py reads OpenRAM output if available; estimates otherwise.
lef: lef_psum lef_actbuf

lef_psum:
	@echo "--- Generating mfn_psum_sram.lef wrapper ---"
	$(PYTHON) gen_psum_lef.py

lef_actbuf:
	@echo "--- Generating sram_act_buf synthetic LEF ---"
	$(PYTHON) gen_act_buf_lef.py

# ── Install ───────────────────────────────────────────
install: lef
	@mkdir -p $(SYN_LIB_DIR) $(PNR_LEF_DIR)
	@cp $(MACRO_A)/$(NAME_A)_TT_1p0V_25C.lib $(SYN_LIB_DIR)/$(NAME_A).lib
	@cp $(MACRO_B)/$(NAME_B)_TT_1p0V_25C.lib $(SYN_LIB_DIR)/$(NAME_B).lib
	@cp macro/mfn_psum_sram.lef              $(PNR_LEF_DIR)/
	@echo ""
	@echo "=== v2 install complete ==="
	@echo "  .lib → $(SYN_LIB_DIR)/$(NAME_A).lib + $(NAME_B).lib"
	@echo "  .lef → $(PNR_LEF_DIR)/mfn_psum_sram.lef"

install_v3: lef_actbuf
	@mkdir -p $(SYN_LIB_DIR) $(PNR_LEF_DIR)/v3
	$(PYTHON) -c "import shutil, os; src='$(MACRO_ACT)/$(NAME_ACT)_TT_1p0V_25C.lib'; dst='$(SYN_LIB_DIR)/$(NAME_ACT).lib'; shutil.copy(src, dst) if os.path.exists(src) else print('WARNING: OpenRAM .lib not found; run make gen_actbuf first')"
	@cp macro/$(NAME_ACT).lef $(PNR_LEF_DIR)/v3/$(NAME_ACT).lef
	@echo ""
	@echo "=== v3 install complete ==="
	@echo "  .lef -> $(PNR_LEF_DIR)/v3/$(NAME_ACT).lef"
	@echo ""
	@echo "Next steps for v3 P&R:"
	@echo "  1. Add $(NAME_ACT).lib to synthesis_v3.tcl library list"
	@echo "  2. Add $(NAME_ACT).lef to init_lef_file in run_innovus_3.tcl"
	@echo "  3. Place macro u_act_buf in floorplan (estimated 111x132 um)"

check:
	$(PYTHON) -c "import openram; print('openram OK:', openram.__file__)"
	@echo "Config psum_A : $(CFG_A)"
	@echo "Config psum_B : $(CFG_B)"
	@echo "Config act_buf: $(CFG_ACT)"

clean:
	rm -rf macro/$(NAME_A) macro/$(NAME_B) macro/$(NAME_ACT)
	rm -f  macro/mfn_psum_sram.lef macro/$(NAME_ACT).lef
	rm -rf __pycache__
	@echo "Cleaned macro directories."
