# ============================================================
# Makefile — OpenRAM SRAM Generation for mfn_psum_sram
#
# Generates two SRAMs that together replace the 512×40 psum_mem FF array:
#
#   SRAM_A  sram_psum_a_1rw1r0w_40_512_freepdk45
#           RW port : write_a (bias/CLA_a result) + read_a (CLA_a operand)
#           R  port : read_c  (psum_to_act activation output)
#
#   SRAM_B  sram_psum_b_1rw0r0w_40_512_freepdk45
#           RW port : write_b (CLA_b result) + read_b (CLA_b operand)
#
# Targets:
#   make gen      — Run OpenRAM for both SRAMs (generates .v .lib .lef .gds)
#   make install  — Copy .lib → ../syn/lib/, .lef → ../../backend/sram_lef/
#   make clean    — Remove generated macro directories
#
# Prerequisites:
#   openram Python package must be importable.
#   If not found: export PYTHONPATH=/path/to/openram/compiler:$PYTHONPATH
# ============================================================

SHELL := /bin/tcsh

PYTHON    := python3.8
COMPILER  := sram_compiler.py

CFG_A     := freepdk45_sram_psum_a_40x512.py
CFG_B     := freepdk45_sram_psum_b_40x512.py

NAME_A    := sram_psum_a_1rw1r0w_40_512_freepdk45
NAME_B    := sram_psum_b_1rw0r0w_40_512_freepdk45

MACRO_A   := macro/$(NAME_A)
MACRO_B   := macro/$(NAME_B)

# Install destinations
SYN_LIB_DIR := ../syn/lib
PNR_LEF_DIR := ../../backend/sram_lef

# -------------------------------------------------------
.PHONY: gen lef_wrapper install clean check

gen: $(MACRO_A)/$(NAME_A).lef $(MACRO_B)/$(NAME_B).lef
	@echo "=== Both SRAM macros generated ==="
	@echo "  SRAM_A : $(MACRO_A)/"
	@echo "  SRAM_B : $(MACRO_B)/"

$(MACRO_A)/$(NAME_A).lef: $(CFG_A) $(COMPILER)
	@echo "--- Generating SRAM_A (1RW+1R, 40-bit x 512) ---"
	$(PYTHON) $(COMPILER) $(CFG_A)

$(MACRO_B)/$(NAME_B).lef: $(CFG_B) $(COMPILER)
	@echo "--- Generating SRAM_B (1RW, 40-bit x 512) ---"
	$(PYTHON) $(COMPILER) $(CFG_B)

# Generate a synthetic mfn_psum_sram.lef whose cell name matches the synthesis
# netlist, with combined footprint of both SRAMs and RTL-matching pin names.
lef_wrapper: gen
	@echo "--- Generating mfn_psum_sram.lef wrapper ---"
	$(PYTHON) gen_psum_lef.py

install: lef_wrapper
	@mkdir -p $(SYN_LIB_DIR) $(PNR_LEF_DIR)
	@cp $(MACRO_A)/$(NAME_A)_TT_1p0V_25C.lib $(SYN_LIB_DIR)/$(NAME_A).lib
	@cp $(MACRO_B)/$(NAME_B)_TT_1p0V_25C.lib $(SYN_LIB_DIR)/$(NAME_B).lib
	@cp macro/mfn_psum_sram.lef $(PNR_LEF_DIR)/
	@echo ""
	@echo "=== Install complete ==="
	@echo "  .lib → $(SYN_LIB_DIR)/"
	@echo "       $(NAME_A).lib  (SRAM_A TT corner)"
	@echo "       $(NAME_B).lib  (SRAM_B TT corner)"
	@echo "  .lef → $(PNR_LEF_DIR)/"
	@echo "       mfn_psum_sram.lef  (wrapper: 275x481 um, matches netlist cell name)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Add .lib to MMMC in mfn_frontend_top_v2.view (Genus + Innovus timing)"
	@echo "  2. Add mfn_psum_sram.lef to init_lef_file in run_innovus_2.tcl"

check:
	$(PYTHON) -c "import openram; print('openram OK:', openram.__file__)"
	@echo "Config A : $(CFG_A)"
	@echo "Config B : $(CFG_B)"
	@echo "Output   : $(MACRO_A)/, $(MACRO_B)/"

clean:
	rm -rf macro/$(NAME_A) macro/$(NAME_B) macro/mfn_psum_sram.lef __pycache__
	@echo "Cleaned macro directories."
