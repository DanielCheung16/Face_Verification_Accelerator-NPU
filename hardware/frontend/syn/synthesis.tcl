# ============================================================
# Genus Synthesis Script — MobileFaceNet Frontend
# Top module : mfn_frontend_top
# Target     : 100 MHz (NangateOpenCellLibrary / FreePDK45)
#
# ROM strategy:
#   All ROM modules are replaced by empty stubs (rom_stubs.sv).
#   They contain $readmemh which is simulation-only and cannot
#   be synthesized. Genus will treat them as black boxes and
#   report them as missing area — this is expected.
#   The critical-path timing report covers:
#     Controller FSM, Addr Gen (2-stage), MAC Array (9×),
#     Activation (2-stage), Sliding Window.
# ============================================================

# ── 1. Libraries ─────────────────────────────────────────────
set_db library     /vol/ece303/genus_tutorial/NangateOpenCellLibrary_typical.lib
set_db lef_library /vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef

# ── 2. Read HDL ──────────────────────────────────────────────
# ROM stubs first (override the simulation-only ROM implementations)
# Then synthesizable RTL modules
read_hdl -sv {
    ./rom_stubs.sv
    ../sv/mfn_sliding_window.sv
    ../sv/mfn_mac_array.sv
    ../sv/mfn_activation.sv
    ../sv/mfn_addr_gen.sv
    ../sv/mfn_controller.sv
    ../sv/mfn_frontend_top.sv
}

# ── 3. Elaborate ─────────────────────────────────────────────
elaborate
current_design mfn_frontend_top

# ── 4. Constraints ───────────────────────────────────────────
read_sdc ./constraints.sdc

# ── 5. Preserve ROM black boxes ──────────────────────────────
# Mark ROM instances as dont_touch so Genus does not try to
# optimize across their (empty) boundaries.
set_db [get_db insts u_wgt_rom] .dont_touch true
set_db [get_db insts u_wgt_rom] .boundary_opto false
set_db [get_db insts u_bias_rom] .dont_touch true
set_db [get_db insts u_bias_rom] .boundary_opto false
set_db [get_db insts u_prelu_rom] .dont_touch true
set_db [get_db insts u_prelu_rom] .boundary_opto false
set_db [get_db insts u_cfg_rom] .dont_touch true
set_db [get_db insts u_cfg_rom] .boundary_opto false

# ── 6. Synthesis ─────────────────────────────────────────────
syn_generic
syn_map
syn_opt

# ── 7. Reports ───────────────────────────────────────────────
report_timing > timing.rep
report_area   > area.rep
report_gates  > gates.rep
report_power  > power.rep

puts ""
puts "======================================================"
puts "  Top critical path (from timing.rep):"
puts "======================================================"
# Show worst negative slack inline
report_timing -nworst 1

# ── 8. Write Netlist ─────────────────────────────────────────
write_hdl > mfn_frontend_top_syn.v

puts ""
puts "=== Synthesis Finished ==="
puts "Reports: timing.rep  area.rep  gates.rep  power.rep"
puts "Netlist: mfn_frontend_top_syn.v"
quit
