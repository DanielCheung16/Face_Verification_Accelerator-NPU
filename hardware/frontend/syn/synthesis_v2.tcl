# ============================================================
# Genus Synthesis Script v2 — MobileFaceNet Frontend
# Top module : mfn_frontend_top
# Target     : 100 MHz (NangateOpenCellLibrary / FreePDK45)
#
# v2 vs v1:
#   - RTL from sv2/: mfn_cla40, mfn_sliding_window, mfn_addr_gen,
#                    mfn_weight_rom (dual-port), mfn_controller,
#                    mfn_frontend_top
#   - RTL from sv/:  mfn_mac_array, mfn_activation (unchanged)
#   - v2_rom_stubs.sv: dual-port weight_rom stub
#   - set_db auto_ungroup none: preserve module hierarchy in Innovus
#
# ROM strategy: same as v1 (simulation-only $readmemh cannot be
#   synthesized; treated as black boxes). See rom_stubs.sv comment.
# ============================================================

# ── 1. Libraries ─────────────────────────────────────────────
set_db library     /vol/ece303/genus_tutorial/NangateOpenCellLibrary_typical.lib
set_db lef_library /vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef

# ── 2. Read HDL ──────────────────────────────────────────────
# v2 ROM stubs first (dual-port weight_rom interface)
read_hdl -sv {
    ./v2_rom_stubs.sv
    ../sv2/mfn_cla40.sv
    ../sv2/mfn_sliding_window.sv
    ../sv2/mfn_addr_gen.sv
    ../sv2/mfn_controller.sv
    ../sv2/mfn_frontend_top.sv
    ../sv/mfn_mac_array.sv
    ../sv/mfn_activation.sv
}

# ── 3. Elaborate ─────────────────────────────────────────────
elaborate
current_design mfn_frontend_top

# ── 4. Constraints ───────────────────────────────────────────
read_sdc ./constraints.sdc

# ── 5. Preserve ROM/SRAM black boxes ─────────────────────────
# Prevent Genus from deleting "unloaded" instances (GLO-34).
# Black-box SRAMs have outputs that feed back through the design;
# Genus cannot trace the dependency and marks them as unloaded.
set_db / .delete_unloaded_insts false

set_db [get_db insts u_wgt_rom]  .dont_touch true
set_db [get_db insts u_wgt_rom]  .boundary_opto false
set_db [get_db insts u_bias_rom] .dont_touch true
set_db [get_db insts u_bias_rom] .boundary_opto false
set_db [get_db insts u_prelu_rom] .dont_touch true
set_db [get_db insts u_prelu_rom] .boundary_opto false
set_db [get_db insts u_cfg_rom]  .dont_touch true
set_db [get_db insts u_cfg_rom]  .boundary_opto false
# psum_sram wrapper is inside u_ctrl; leaf macros are one level deeper
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_a] .dont_touch true
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_a] .boundary_opto false
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_a] .preserve true
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_b] .dont_touch true
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_b] .boundary_opto false
set_db [get_db insts u_ctrl/u_psum_mem/u_sram_b] .preserve true

# ── 6. Preserve module hierarchy ─────────────────────────────
# Prevents syn_opt from flattening sub-modules so Innovus can
# show each module's placement region separately.
set_db / .auto_ungroup none

# ── 7. Synthesis ─────────────────────────────────────────────
syn_generic
syn_map
syn_opt

# ── 8. Reports ───────────────────────────────────────────────
report_timing > timing_v2.rep
report_area   > area_v2.rep
report_gates  > gates_v2.rep
report_power  > power_v2.rep

puts ""
puts "======================================================"
puts "  Top critical path (from timing_v2.rep):"
puts "======================================================"
report_timing -nworst 1

# ── 9. Write Netlist ─────────────────────────────────────────
write_hdl > mfn_frontend_top_v2_syn.v

puts ""
puts "=== v2 Synthesis Finished ==="
puts "Reports: timing_v2.rep  area_v2.rep  gates_v2.rep  power_v2.rep"
puts "Netlist: mfn_frontend_top_v2_syn.v"
quit
