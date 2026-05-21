# ============================================================
# Genus Synthesis Script v3 — MobileFaceNet Frontend
# Top module : mfn_frontend_top_v3
# Target     : 83 MHz / 12 ns (NangateOpenCellLibrary / FreePDK45)
#              (matches v2 P&R constraint; WNS was +2.9 ns → headroom exists)
#
# v3 vs v2:
#   SA       : 12×12 = 144-MAC array (v2 was dual 9-MAC)
#   New RTL  : mfn_sa_12x12, mfn_pe, mfn_act_buf, mfn_controller_v3
#   Shared   : mfn_activation (unchanged)
#   Stubs    : mfn_weight_rom_v3 (12-port, $readmemh → black box)
#              mfn_psum_sram + psum OpenRAM macros (identical to v2)
#
# act_buf: SRAM macro (v3+ opt④).  mfn_act_buf is a thin wrapper around the
#   192-bit × 64 OpenRAM SRAM (sram_act_buf_1rw0r0w_192_64_freepdk45) — the
#   SRAM leaf u_act_buf/u_sram is black-boxed; the wrapper logic synthesizes.
#   Replaces the former 168 K-cell FF array.
#
# Usage: genus -batch -files synthesis_v3.tcl
#        (run from hardware/frontend/syn/)
# ============================================================

# ── 1. Libraries ─────────────────────────────────────────────
set_db library     /vol/ece303/genus_tutorial/NangateOpenCellLibrary_typical.lib
set_db lef_library /vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef

# Also load SRAM .lib so Genus knows macro timing:
#   psum SRAM_A/B (same as v2) + act_buf SRAM (v3+ opt④, 192-bit × 64)
set_db library [concat \
    /vol/ece303/genus_tutorial/NangateOpenCellLibrary_typical.lib \
    ./lib/sram_psum_a_1rw1r0w_40_512_freepdk45.lib \
    ./lib/sram_act_buf_1rw0r0w_192_64_freepdk45.lib \
]

# ── 2. Read HDL ──────────────────────────────────────────────
# v3 ROM/SRAM stubs first (weight_rom_v3 + OpenRAM macro wrappers)
read_hdl -sv {
    ./v3_rom_stubs.sv
    ../sv3/mfn_pe.sv
    ../sv3/mfn_sa_12x12.sv
    ../sv3/mfn_act_buf.sv
    ../sv3/mfn_activation.sv
    ../sv3/mfn_controller_v3.sv
    ../sv3/mfn_frontend_top_v3.sv
}

# ── 3. Elaborate ─────────────────────────────────────────────
elaborate
current_design mfn_frontend_top_v3

# ── 4. Constraints ───────────────────────────────────────────
# Reuse v2 constraints (same target 83 MHz / 12 ns clock period)
read_sdc ./constraints_v3.sdc

# ── 5. Black-box ROM / SRAM instances ────────────────────────
# NOTE: only 'dont_touch true' is used.  'boundary_opto' and 'preserve' caused
# TUI-183 (not valid 'inst' attributes in this Genus version).  The ROM/SRAM
# stubs in v3_rom_stubs.sv are empty modules → Genus auto-treats them as logic
# abstracts (black boxes); dont_touch additionally locks the instances.
set_db / .delete_unloaded_insts false

# Weight ROM v3: 12-port, too large/multi-port to synthesize
set_db [get_db insts u_wgt_rom]   .dont_touch true

# Bias / PReLU / layer-config ROMs (same as v2)
set_db [get_db insts u_bias_rom]  .dont_touch true
set_db [get_db insts u_prelu_rom] .dont_touch true
set_db [get_db insts u_cfg_rom]   .dont_touch true

# psum SRAM macro — v3 uses ONLY SRAM_A (u_psum_mem is at TOP level in v3).
# SRAM_B was dropped (v3 never uses psum port B).
set_db [get_db insts u_psum_mem/u_sram_a] .dont_touch true

# act_buf SRAM macro (v3+ opt④): mfn_act_buf is now a thin wrapper around the
# 192-bit × 64 OpenRAM SRAM.  Black-box the SRAM leaf; the wrapper logic
# (channel↔word mapping, write mask) synthesizes normally.
set_db [get_db insts u_act_buf/u_sram] .dont_touch true

# ── 6. Preserve module hierarchy ─────────────────────────────
set_db / .auto_ungroup none

# ── 7. Synthesis ─────────────────────────────────────────────
syn_generic
syn_map
syn_opt

# ── 8. Reports ───────────────────────────────────────────────
report_timing > timing_v3.rep
report_area   > area_v3.rep
report_gates  > gates_v3.rep
report_power  > power_v3.rep

puts ""
puts "======================================================"
puts "  Top critical path (from timing_v3.rep):"
puts "======================================================"
report_timing -nworst 3

# ── 9. Write Netlist ─────────────────────────────────────────
write_hdl > mfn_frontend_top_v3_syn.v

puts ""
puts "=== v3 Synthesis Finished ==="
puts "Reports: timing_v3.rep  area_v3.rep  gates_v3.rep  power_v3.rep"
puts "Netlist: mfn_frontend_top_v3_syn.v"
puts "Note: act_buf synthesized as FF array (8192 FFs, ~large area)"
puts "      weight_rom_v3 and ROMs are black boxes (not in netlist)"
quit
