# ============================================================
# Genus Synthesis Script v3 — MobileFaceNet Frontend
# Top module : mfn_frontend_top_v3
# Target     : 83 MHz / 12 ns (NangateOpenCellLibrary / FreePDK45)
#              (matches v2 P&R constraint; WNS was +2.9 ns → headroom exists)
#
# v3 vs v2:
#   SA       : 12×12 output-stationary (was 6×1)
#   New RTL  : mfn_sa_12x12, mfn_pe, mfn_act_buf, mfn_controller_v3
#   Shared   : mfn_activation (unchanged)
#   Stubs    : mfn_weight_rom_v3 (12-port, $readmemh → black box)
#              mfn_psum_sram + OpenRAM macros (identical to v2)
#
# act_buf: synthesized as FF array (512×16-bit = 8192 FFs).
#   Area impact: large; future work could replace with 512×16 SRAM macro.
#   For now: synthesize normally, set dont_touch=false (Genus optimizes it).
#
# Usage: genus -batch -files synthesis_v3.tcl
#        (run from hardware/frontend/syn/)
# ============================================================

# ── 1. Libraries ─────────────────────────────────────────────
set_db library     /vol/ece303/genus_tutorial/NangateOpenCellLibrary_typical.lib
set_db lef_library /vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef

# Also load SRAM .lib so Genus knows psum SRAM timing (same macros as v2)
set_db library [concat \
    /vol/ece303/genus_tutorial/NangateOpenCellLibrary_typical.lib \
    ./lib/sram_psum_a_1rw1r0w_40_512_freepdk45.lib \
    ./lib/sram_psum_b_1rw0r0w_40_512_freepdk45.lib \
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
set_db / .delete_unloaded_insts false

# Weight ROM v3: 12-port, too large/multi-port to synthesize
set_db [get_db insts u_wgt_rom]   .dont_touch true
set_db [get_db insts u_wgt_rom]   .boundary_opto false

# Bias / PReLU / layer-config ROMs (same as v2)
set_db [get_db insts u_bias_rom]  .dont_touch true
set_db [get_db insts u_bias_rom]  .boundary_opto false
set_db [get_db insts u_prelu_rom] .dont_touch true
set_db [get_db insts u_prelu_rom] .boundary_opto false
set_db [get_db insts u_cfg_rom]   .dont_touch true
set_db [get_db insts u_cfg_rom]   .boundary_opto false

# psum SRAM OpenRAM macros (identical to v2)
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_a] .dont_touch true
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_a] .boundary_opto false
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_a] .preserve true
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_b] .dont_touch true
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_b] .boundary_opto false
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_b] .preserve true

# act_buf: FF array, synthesize normally (do NOT set dont_touch)
# 512×16 = 8192 FFs → Genus will register-pack and optimize
# Critical path through act_buf is combinational (read is async)

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
