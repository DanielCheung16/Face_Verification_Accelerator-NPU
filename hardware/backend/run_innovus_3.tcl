# ============================================================
# Innovus P&R Script v3 — MobileFaceNet Frontend
# Top module : mfn_frontend_top_v3
# Target     : 83 MHz / 12 ns (NangateOpenCellLibrary / FreePDK45)
#
# v3 vs v2:
#   - 12×12 output-stationary SA (was 6×1), dw_mode diagonal path
#   - mfn_act_buf synthesized as FF array (87K cells, ~152K µm²)
#   - mfn_controller_v3: DW-12-parallel + bias-preload + act-preload
#   - Weight ROM (mfn_weight_rom_v3) is 0-cell black box → Innovus warns, ok
#   - Floorplan: 1000×900 µm core (~41% stdcell util)
#   - Same psum SRAM macros (u_sram_a + u_sram_b) as v2
#   - Same M4 blockage fix for SRAM_B dout0 SHORTs
#   - addFiller post-route (same fix as v2: avoids IMPOPT-310)
# ============================================================

# ── 1. Design Import ─────────────────────────────────────────
setDesignMode -process 45

set init_verilog      "../frontend/syn/mfn_frontend_top_v3_syn.v"
set init_top_cell     "mfn_frontend_top_v3"
set init_lef_file     [list \
    "/vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef" \
    "./sram_lef/sram_psum_a_1rw1r0w_40_512_freepdk45_fixed.lef" \
    "./sram_lef/sram_psum_b_1rw0r0w_40_512_freepdk45_fixed.lef" \
]
set init_mmmc_file    "./mfn_frontend_top_v3.view"
set init_pwr_net      "VDD"
set init_gnd_net      "VSS"

# Must be set before init_design: SRAM .lib uses fF, stdcell .lib uses pF
setLibraryUnit -cap 1ff

init_design

# ── 2. Floorplan ─────────────────────────────────────────────
# Cell area (area_v3.rep, opt④ netlist): 455,340 µm²
#   (u_act_buf 260K — FF array + 12-lane wide-write mux — dominates; u_sa 177K)
# psum SRAM macros: SRAM_A 275.49×240.50=66,265 µm²  SRAM_B 158.995×204.86=32,571 µm²
# 1100×1000 core = 1,100,000 µm²; available for cells = 1,100,000−98,836 = 1,001,164 µm²
# Stdcell utilization: 455,340 / 1,001,164 ≈ 45%  (leaves routing margin)
floorPlan -s 1100 1000 5 5 5 5
fit

# ── 2b. SRAM Macro Placement ─────────────────────────────────
# Same psum SRAM footprints and positions as v2 (lower-left corner of die).
# SRAM_A (275.49 × 240.50 µm): origin (10,10)
# SRAM_B (158.995 × 204.86 µm): origin (10,280) — 29.5 µm gap above SRAM_A top
placeInstance u_ctrl/u_psum_mem/u_sram_a 10 10 R0
placeInstance u_ctrl/u_psum_mem/u_sram_b 10 280 R0

# ── 3. Power Connections ─────────────────────────────────────
globalNetConnect VDD -type pgpin -pin VDD -inst *
globalNetConnect VSS -type pgpin -pin VSS -inst *
# OpenRAM SRAMs use lowercase vdd/gnd inout ports
globalNetConnect VDD -type pgpin -pin vdd -inst *
globalNetConnect VSS -type pgpin -pin gnd -inst *
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

# ── 3b. Placement Blockage around psum SRAMs ─────────────────
# 25 µm right of SRAM_A, 31 µm right of SRAM_B routing corridors (same as v2).
# Extra core width (1000 µm vs 560 µm) gives the FF-array stdcells room to spread right.
#   SRAM_A footprint (10,10)-(285.5,250.5) → block (5,5)-(310,276)
#   SRAM_B footprint (10,280)-(169,484.9) → block (5,275)-(200,495)
createPlaceBlockage -type hard -box {5 5 310 276}
createPlaceBlockage -type hard -box {5 275 200 495}

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

# Wider die → increase stripe count: set_to_set_distance 50 → ~20 pairs across 1000 µm
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
set_ccopt_property -pin u_ctrl/u_psum_mem/u_sram_a/clk0 sink_type stop
set_ccopt_property -pin u_ctrl/u_psum_mem/u_sram_a/clk0 \
    -delay_corner dc_typical capacitance_override 50
set_ccopt_property -pin u_ctrl/u_psum_mem/u_sram_a/clk1 sink_type stop
set_ccopt_property -pin u_ctrl/u_psum_mem/u_sram_a/clk1 \
    -delay_corner dc_typical capacitance_override 50
set_ccopt_property -pin u_ctrl/u_psum_mem/u_sram_b/clk0 sink_type stop
set_ccopt_property -pin u_ctrl/u_psum_mem/u_sram_b/clk0 \
    -delay_corner dc_typical capacitance_override 50

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
puts "    act_buf as FF array (87K cells, 152K µm²; no SRAM macro)"
puts "    DW-12-parallel + bias-preload + act-preload controller"
puts "    Floorplan: 1000×900 µm core (~41% stdcell util)"
puts "    Same M4 SRAM blockage fix as v2"
puts "    addFiller post-route (avoids IMPOPT-310)"
puts "  Target: 83 MHz / 12 ns"
puts "  Reports : mfn_frontend_top_v3.{drc,conn,antenna}.rpt"
puts "            pnr_v3_timing.rep  pnr_v3_power.rep"
puts "  Netlist : mfn_frontend_top_v3_final_nophy.v"
puts "======================================================"
