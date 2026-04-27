# ============================================================
# Makefile for MobileFaceNet Frontend Simulation (Cadence Xcelium xrun)
# ============================================================
# Usage:
#   make addr_gen    — Test Address Generator (Padding logic)
#   make weight_rom  — Test Weight ROM (192-bit unpacking)
#   make config_rom  — Test Layer Config ROM (58 layers)
#   make all         — Run all unit testbenches
#   make clean       — Remove xcelium artifacts
# ============================================================

SV_DIR  := ../sv
SIM_DIR := ../sv
XFLAGS  := -sv -access +rwc -timescale 1ns/1ps -64bit
ENV_FILE := /vol/ece303/genus_tutorial/cadence.env
SHELL := /bin/tcsh

# Source files
ADDR_GEN_SRC   := $(SV_DIR)/mfn_addr_gen.sv
WEIGHT_ROM_SRC := $(SV_DIR)/mfn_weight_rom.sv
CONFIG_ROM_SRC := $(SV_DIR)/mfn_layer_config_rom.sv
ALL_SV_SRC     := $(SV_DIR)/mfn_frontend_top.sv \
                  $(SV_DIR)/mfn_controller.sv \
                  $(SV_DIR)/mfn_addr_gen.sv \
                  $(SV_DIR)/mfn_sliding_window.sv \
                  $(SV_DIR)/mfn_mac_array.sv \
                  $(SV_DIR)/mfn_activation.sv \
                  $(SV_DIR)/mfn_weight_rom.sv \
                  $(SV_DIR)/mfn_bias_rom.sv \
                  $(SV_DIR)/mfn_prelu_rom.sv \
                  $(SV_DIR)/mfn_layer_config_rom.sv

# Testbenches
ADDR_GEN_TB    := $(SV_DIR)/mfn_addr_gen_tb.sv
WEIGHT_ROM_TB  := $(SV_DIR)/mfn_weight_rom_tb.sv
CONFIG_ROM_TB  := $(SV_DIR)/mfn_layer_config_rom_tb.sv
TOP_TB         := $(SV_DIR)/mfn_frontend_top_tb.sv

# -------------------------------------------------------
.PHONY: all addr_gen weight_rom config_rom top clean

all: addr_gen weight_rom config_rom top

addr_gen:
	source $(ENV_FILE); xrun $(XFLAGS) $(ADDR_GEN_SRC) $(ADDR_GEN_TB)

weight_rom:
	source $(ENV_FILE); xrun $(XFLAGS) $(WEIGHT_ROM_SRC) $(WEIGHT_ROM_TB)

config_rom:
	source $(ENV_FILE); xrun $(XFLAGS) $(CONFIG_ROM_SRC) $(CONFIG_ROM_TB)

top:
	source $(ENV_FILE); xrun $(XFLAGS) $(ALL_SV_SRC) $(TOP_TB)

# GUI mode
addr_gen_gui:
	source $(ENV_FILE); xrun $(XFLAGS) -gui $(ADDR_GEN_SRC) $(ADDR_GEN_TB)

top_gui:
	source $(ENV_FILE); xrun $(XFLAGS) -gui $(ALL_SV_SRC) $(TOP_TB)

clean:
	rm -rf xcelium.d INCA_libs xrun.log xrun.history waves.shm *.key
	@echo "Cleaned."