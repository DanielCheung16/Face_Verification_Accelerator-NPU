# ============================================================
# Innovus P&R Script — MobileFaceNet Frontend
# Top module : mfn_frontend_top
# Target     : 100 MHz (NangateOpenCellLibrary / FreePDK45)
# ============================================================

# ── 1. Design Import ─────────────────────────────────────────
setDesignMode -process 45

set init_verilog      "./mfn_frontend_top_syn_pg.v"
set init_top_cell     "mfn_frontend_top"
set init_lef_file     "/vol/ece303/genus_tutorial/NangateOpenCellLibrary.lef"
set init_mmmc_file    "./mfn_frontend_top.view"
set init_pwr_net      "VDD"
set init_gnd_net      "VSS"

init_design

# ── 2. Floorplan ─────────────────────────────────────────────
# Aspect ratio 1.0, 50% utilization, 5 µm margins
# Cell area = 182,530 µm² → core ≈ 365,000 µm² → ~604 µm side
floorPlan -r 1.0 0.5 5 5 5 5
fit

# ── 3. Power Connections ─────────────────────────────────────
globalNetConnect VDD -type pgpin -pin VDD -inst *
globalNetConnect VSS -type pgpin -pin VSS -inst *
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

# ── 4. Pin Placement ─────────────────────────────────────────
# Inputs (clk, rst_n, start, pixel data) → Left
# Outputs (done, valid, SRAM addr/data)  → Right
editPin -side Left  -pin {clk rst_n start_inference pixel_in*} \
        -layer 3 -spreadType Center -spacing 0.5
editPin -side Right -pin {inference_done valid_out sram_rd_addr* sram_wr_addr* pixel_out*} \
        -layer 3 -spreadType Center -spacing 0.5

# ── 5. Power Planning ─────────────────────────────────────────
addRing -nets {VSS VDD} -type core_rings -follow io \
        -layer {top metal5 bottom metal5 left metal4 right metal4} \
        -width   {top 1 bottom 1 left 1 right 1} \
        -spacing {top 1 bottom 1 left 1 right 1} \
        -offset  {top 0 bottom 0 left 0 right 0} \
        -center 0

addStripe -block_ring_top_layer_limit metal5 \
          -max_same_layer_jog_length 1.6 \
          -padcore_ring_bottom_layer_limit metal3 \
          -set_to_set_distance 5 \
          -stacked_via_top_layer metal10 \
          -padcore_ring_top_layer_limit metal5 \
          -spacing 1 -xleft_offset 1 -merge_stripes_value 0.095 \
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

# ── 7. Clock Tree Synthesis (CTS) ────────────────────────────
set_ccopt_property buffer_cells {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3}
set_ccopt_property use_inverters false
create_ccopt_clock_tree_spec
ccopt_design

# ── 8. Post-CTS Optimization ─────────────────────────────────
setAnalysisMode -analysisType onChipVariation
optDesign -postCTS
optDesign -postCTS -hold

# ── 9. Routing ───────────────────────────────────────────────
setNanoRouteMode -quiet -routeTopRoutingLayer 10
routeDesign -globalDetail

# ── 10. Post-Route Optimization ──────────────────────────────
setExtractRCMode -engine postRoute
extractRC
optDesign -postRoute
optDesign -postRoute -hold

# ── 11. Verification ─────────────────────────────────────────
verify_drc          -report mfn_frontend_top.drc.rpt
verifyConnectivity  -type all -report mfn_frontend_top.conn.rpt
verifyProcessAntenna -reportfile mfn_frontend_top.antenna.rpt

# ── 12. Save ─────────────────────────────────────────────────
saveDesign   mfn_frontend_top_final.enc
saveNetlist  mfn_frontend_top_final_nophy.v
write_sdf    mfn_frontend_top_final.sdf

# Timing summary
report_timing > pnr_timing.rep
report_power  > pnr_power.rep

puts ""
puts "======================================================"
puts "  Innovus P&R Finished — mfn_frontend_top"
puts "  Reports : mfn_frontend_top.{drc,conn,antenna}.rpt"
puts "           pnr_timing.rep  pnr_power.rep"
puts "  Netlist : mfn_frontend_top_final_nophy.v"
puts "======================================================"
