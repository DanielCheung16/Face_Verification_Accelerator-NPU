# ============================================================
# Innovus P&R Script v3 — MobileFaceNet Frontend
# Top module : mfn_frontend_top_v3
# Target     : 200 MHz / 5.0 ns (NangateOpenCellLibrary / FreePDK45)
#              (note §35 Stage 3 max-push; 5.75 ns post-route had slack
#               +0.565 ns with critical path on Stage 3's row_dot_reg)
#
# v3 vs v2:
#   - 12×12 = 144-MAC output-stationary array (was dual 9-MAC)
#   - mfn_controller_v3: opt①②③④ (DW-12-parallel, preloads, 12-ch wide fetch)
#       + S_DW_DRAIN (1-cycle drain for the global DW path's Stage 3 pipeline)
#   - 2 SRAM macros: psum SRAM_A + act_buf SRAM (192-bit × 64).
#     psum SRAM_B dropped — v3 never uses psum port B.
#   - act_buf SRAM: registered output (2-cycle read latency) → SA full cycle
#   - mfn_activation: 4-stage pipeline (stage-0 input reg + stage-2A mult / 2B
#     MUX+residual+clamp split).  Controller adds 3 drain wait cycles after
#     S_SPATIAL_LOOP so the last pixel reaches valid_out before TB dump.
#   - mfn_sa_12x12: Stage 3 — row_dot_reg (12 × 40-bit) + enable_d break the
#     mult+CSA-tree away from the final +acc add (480 FF added).
#   - Weight ROM (mfn_weight_rom_v3) is 0-cell black box → Innovus warns, ok
#   - SRAM LEFs patched (fix_sram_lef.py): M3/M4 OBS stripped → dout routable
#   - addFiller post-route (same fix as v2: avoids IMPOPT-310)
# ============================================================

# ── 1. Design Import ─────────────────────────────────────────
setDesignMode -process 45

set init_verilog      "../frontend/syn/mfn_frontend_top_v3_syn.v"
set init_top_cell     "mfn_frontend_top_v3"
set init_lef_file     [list \
    "/vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef" \
    "./sram_lef/sram_psum_a_1rw1r0w_40_512_freepdk45_fixed.lef" \
    "./sram_lef/v3/sram_act_buf_1rw0r0w_192_64_freepdk45_fixed.lef" \
]
set init_mmmc_file    "./mfn_frontend_top_v3.view"
set init_pwr_net      "VDD"
set init_gnd_net      "VSS"

# Must be set before init_design: SRAM .lib uses fF, stdcell .lib uses pF
setLibraryUnit -cap 1ff

init_design

# ── 2. Floorplan ─────────────────────────────────────────────
# 200 MHz / 5.0 ns version: stdcell cell area ≈ 193,422 µm² (genus.log9).
# Macros: psum SRAM_A 66,255 µm² + act_buf SRAM (639.37×152.365) 97,420 µm²
#         → 163,675 µm² of macro.
# 720×720 core = 518,400 µm²; available for cells ≈ 354,725 µm².
# Stdcell utilization ≈ 55%; Innovus placement density typically ~58-60%.
#   (Previous 800×700 ran at 52.87% density with +0.257 ns slack — shrinking
#    to 720×720 saves 7.4% area and 45 µm of max diagonal for slightly shorter
#    nets / clock tree.  Density stays inside Innovus's comfort zone (<65%).)
floorPlan -s 720 720 5 5 5 5
fit

# ── 2b. SRAM Macro Placement (2 macros) ──────────────────────
# psum SRAM_A (275.49 × 240.50 µm): lower-left, origin (10,10).
# (v3 uses only SRAM_A — psum SRAM_B dropped, port B unused.)
placeInstance u_psum_mem/u_sram_a 10 10 R0
# act_buf SRAM (v3+ opt④, 639.37 × 152.365 µm): wide macro along the top edge.
# (10,545)-(649.4,697.4) — slid up 10 µm from the 800×700 layout to keep the
# routing channel above the macro non-zero (was 12 µm there, now 17 µm here)
# while leaving 545−250 = 295 µm of clean stdcell space between psum and act_buf.
placeInstance u_act_buf/u_sram 10 545 R0

# ── 3. Power Connections ─────────────────────────────────────
globalNetConnect VDD -type pgpin -pin VDD -inst *
globalNetConnect VSS -type pgpin -pin VSS -inst *
# OpenRAM SRAMs use lowercase vdd/gnd inout ports
globalNetConnect VDD -type pgpin -pin vdd -inst *
globalNetConnect VSS -type pgpin -pin gnd -inst *
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

# ── 3b. Placement Blockage around macros ─────────────────────
# Keep stdcells a little clear of the macros for routing corridors.
#   psum SRAM_A footprint (10,10)-(285.5,250.5)   → block (5,5)-(310,276)
#   act_buf SRAM footprint (10,545)-(649.4,697.4) → block (5,540)-(655,702)
createPlaceBlockage -type hard -box {5 5 310 276}
createPlaceBlockage -type hard -box {5 540 655 702}

# ── 3c. SRAM Routing Obstruction Note ────────────────────────
# No createRouteBlk over the SRAM bodies.  fix_sram_lef.py strips the
# over-conservative M3/M4 OBS from both synthetic OpenRAM LEFs (M1/M2 kept),
# so the router can place via3 on the M3 dout pins and route M4 over the
# macros normally.  See run_innovus_2.tcl §3c for the full rationale.

# ── 4. Pin Placement ─────────────────────────────────────────
# v3 ports differ from v2: controller outputs reset_ptr/inc_write/read_res/x_out/y_out/c_in_out
editPin -side Left  -pin {clk rst_n start_inference pixel_in*} \
        -layer 3 -spreadType Center -spacing 0.5
editPin -side Right -pin {inference_done valid_out reset_ptr inc_write read_res \
                           x_out* y_out* c_in_out* pixel_out*} \
        -layer 3 -spreadType Center -spacing 0.5

# ── 5. Power Planning ─────────────────────────────────────────
addRing -nets {VSS VDD} -type core_rings -follow io \
        -layer {top metal5 bottom metal5 left metal4 right metal4} \
        -width   {top 1 bottom 1 left 1 right 1} \
        -spacing {top 1 bottom 1 left 1 right 1} \
        -offset  {top 0 bottom 0 left 0 right 0} \
        -center 0

# 720-wide core: set_to_set_distance 50 → ~14 VDD/VSS stripe pairs.
addStripe -block_ring_top_layer_limit metal5 \
          -max_same_layer_jog_length 1.6 \
          -padcore_ring_bottom_layer_limit metal3 \
          -set_to_set_distance 50 \
          -stacked_via_top_layer metal10 \
          -padcore_ring_top_layer_limit metal5 \
          -spacing 1 -xleft_offset 50 -merge_stripes_value 0.095 \
          -layer metal4 \
          -block_ring_bottom_layer_limit metal3 \
          -width 1 -nets {VSS VDD} \
          -stacked_via_bottom_layer metal1

sroute -connect { blockPin padPin padRing corePin floatingStripe } \
       -layerChangeRange { 1 10 } \
       -blockPinTarget { nearestRingStripe nearestTarget } \
       -padPinPortConnect { allPort oneGeom } \
       -checkAlignedSecondaryPin 1 -blockPin useLef \
       -allowJogging 1 -crossoverViaBottomLayer 1 \
       -allowLayerChange 1 -targetViaTopLayer 10 \
       -crossoverViaTopLayer 10 -targetViaBottomLayer 1 \
       -nets { VDD VSS }

# ── 6. Placement ─────────────────────────────────────────────
setPlaceMode -timingDriven 1 -clkGateAware 1
placeDesign

# ── 7. CTS NDR Definition ────────────────────────────────────
# Same NDR rules as v2 (FreePDK45 min widths unchanged).
# CTS_2W1S (leaf): Double-Width / Single-Spacing on M1–M4
add_ndr -name CTS_2W1S \
    -width   {metal1 0.14 metal2 0.14 metal3 0.14 metal4 0.28} \
    -spacing {metal1 0.07 metal2 0.07 metal3 0.07 metal4 0.14}

# CTS_2W2S (trunk): Double-Width / Double-Spacing + VSS shield on M7–M10
add_ndr -name CTS_2W2S \
    -width   {metal7 0.8  metal8 0.8  metal9 1.6  metal10 1.6} \
    -spacing {metal7 0.42 metal8 0.42 metal9 0.84 metal10 0.84}

create_route_type -name leaf_rule \
    -non_default_rule CTS_2W1S \
    -top_preferred_layer    metal4 \
    -bottom_preferred_layer metal1

create_route_type -name trunk_rule \
    -non_default_rule CTS_2W2S \
    -top_preferred_layer    metal10 \
    -bottom_preferred_layer metal7 \
    -shield_net VSS \
    -bottom_shield_layer metal7

set_ccopt_property route_type -net_type leaf  leaf_rule
set_ccopt_property route_type -net_type trunk trunk_rule

# ── 8. Clock Tree Synthesis (CTS) ────────────────────────────
set_ccopt_property buffer_cells {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3}
set_ccopt_property use_inverters false

# Mark all SRAM clock pins as stop sinks — macros have no timing data.
set_ccopt_property -pin u_psum_mem/u_sram_a/clk0 sink_type stop
set_ccopt_property -pin u_psum_mem/u_sram_a/clk0 \
    -delay_corner dc_typical capacitance_override 50
set_ccopt_property -pin u_psum_mem/u_sram_a/clk1 sink_type stop
set_ccopt_property -pin u_psum_mem/u_sram_a/clk1 \
    -delay_corner dc_typical capacitance_override 50
set_ccopt_property -pin u_act_buf/u_sram/clk0 sink_type stop
set_ccopt_property -pin u_act_buf/u_sram/clk0 \
    -delay_corner dc_typical capacitance_override 50

# Explicit skew / slew targets — give CCOpt firm goals so the clock tree is
# balanced more uniformly.  Combined with the tighter 720×720 floorplan
# (max diagonal 1018 µm vs 1063 µm at 800×700), this shortens and evens
# out the tree.  Prior 800×700 / 5.0 ns runs landed at skew 0.069 ns,
# insertion delay 0.357–0.426 ns (avg 0.409, sd 0.012).
set_ccopt_property target_skew      0.050
set_ccopt_property target_max_trans 0.100

create_ccopt_clock_tree_spec
ccopt_design

# ── 9. Post-CTS Optimization ─────────────────────────────────
setAnalysisMode -analysisType onChipVariation

timeDesign -postCTS
optDesign  -postCTS

timeDesign -postCTS -hold
optDesign  -postCTS -hold

# ── 10. Routing ──────────────────────────────────────────────
# addFiller moved to AFTER post-route optimization (step 12).
# Prevents IMPOPT-310 "density 100%" when hold optimizer needs to insert buffers.
setNanoRouteMode -quiet -routeTopRoutingLayer 10
routeDesign -globalDetail

# ── 11. Post-Route Optimization ──────────────────────────────
setExtractRCMode -engine postRoute
extractRC

timeDesign -postRoute
optDesign  -postRoute

timeDesign -postRoute -hold
# holdTargetSlack=0.0: only fix genuinely-negative hold slack.
# Reduces hold-buffer insertions near SRAM that would route through M4 OBS.
setOptMode -holdTargetSlack 0.0 -setupTargetSlack 0.0
optDesign  -postRoute -hold

# ── 12. Filler Insertion (post-route) ────────────────────────
# Inserted here so hold optimization had full placement headroom (avoids IMPOPT-310).
addFiller \
    -cell {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1} \
    -prefix FILL

# ── 13. Verification ─────────────────────────────────────────
verify_drc          -report mfn_frontend_top_v3.drc.rpt
verifyConnectivity  -type all -report mfn_frontend_top_v3.conn.rpt
verifyProcessAntenna -reportfile mfn_frontend_top_v3.antenna.rpt

# ── 14. Reports ──────────────────────────────────────────────
report_timing > pnr_v3_timing.rep
report_power  > pnr_v3_power.rep

# ── 15. Save ─────────────────────────────────────────────────
saveDesign  mfn_frontend_top_v3_final.enc
saveNetlist mfn_frontend_top_v3_final_nophy.v
write_sdf   mfn_frontend_top_v3_final.sdf

puts ""
puts "======================================================"
puts "  Innovus P&R v3 Finished — mfn_frontend_top_v3"
puts "  v3 additions:"
puts "    12×12 output-stationary SA (dw_mode diagonal)"
puts "    act_buf SRAM (192×64 OpenRAM macro, 2-cyc registered read)"
puts "    psum SRAM_A only (port B dropped)"
puts "    DW-12-parallel + bias-preload + act-preload controller"
puts "    Floorplan: 720×720 µm core (~55% stdcell util)"
puts "    M3/M4 SRAM OBS stripped via fix_sram_lef.py"
puts "    addFiller post-route (avoids IMPOPT-310)"
puts "    mfn_activation 4-stage pipeline (Stage 0+2 split, note §35)"
puts "    SA Stage 3: row_dot_reg between mult+CSA tree and acc add"
puts "  Target: 200 MHz / 5.0 ns"
puts "  Reports : mfn_frontend_top_v3.{drc,conn,antenna}.rpt"
puts "            pnr_v3_timing.rep  pnr_v3_power.rep"
puts "  Netlist : mfn_frontend_top_v3_final_nophy.v"
puts "======================================================"
