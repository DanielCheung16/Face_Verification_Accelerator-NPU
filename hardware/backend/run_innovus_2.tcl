# ============================================================
# Innovus P&R Script v2 — MobileFaceNet Frontend
# Top module : mfn_frontend_top
# Target     : 100 MHz (NangateOpenCellLibrary / FreePDK45)
#
# v2 improvements over v1:
#   1. CTS NDR (CTS_2W1S leaf + CTS_2W2S trunk w/ VSS shielding)
#   2. create_route_type mapping for CCOpt
#   3. timeDesign calls before each optDesign (timing visibility)
#   4. Filler insertion before routing (N-well continuity, M1 rails)
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
floorPlan -r 1.0 0.5 5 5 5 5
fit

# ── 3. Power Connections ─────────────────────────────────────
globalNetConnect VDD -type pgpin -pin VDD -inst *
globalNetConnect VSS -type pgpin -pin VSS -inst *
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

# ── 4. Pin Placement ─────────────────────────────────────────
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

# ── 7. CTS NDR Definition ────────────────────────────────────
# [v2 NEW] Non-Default Rules for clock routing
# FreePDK45 min widths: M1-M3=0.07µm, M4=0.14µm, M7-M8=0.4µm, M9-M10=0.8µm
#
# CTS_2W1S (leaf): Double-Width / Single-Spacing → M1–M4
#   Keeps leaf distribution on lower metals; wider wire = lower resistance = less skew
create_ndr -name CTS_2W1S \
    -width   {metal1 0.14 metal2 0.14 metal3 0.14 metal4 0.28} \
    -spacing {metal1 0.07 metal2 0.07 metal3 0.07 metal4 0.14}

# CTS_2W2S (trunk): Double-Width / Double-Spacing + VSS shield → M7–M10
#   Wide/spaced trunk on top metals = low RC + EMI immunity
#   VSS shield on M7 absorbs crosstalk from adjacent signal wires
create_ndr -name CTS_2W2S \
    -width   {metal7 0.8  metal8 0.8  metal9 1.6  metal10 1.6} \
    -spacing {metal7 0.42 metal8 0.42 metal9 0.84 metal10 0.84}

# Map NDRs to leaf / trunk route types
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
create_ccopt_clock_tree_spec
ccopt_design

# ── 9. Post-CTS Optimization ─────────────────────────────────
setAnalysisMode -analysisType onChipVariation

# [v2 NEW] timeDesign first → gives a timing snapshot before optDesign modifies anything
timeDesign -postCTS
optDesign  -postCTS

timeDesign -postCTS -hold
optDesign  -postCTS -hold

# ── 10. Filler Insertion ─────────────────────────────────────
# [v2 NEW] Must be done before routing.
# Fills placement gaps for N-well continuity and M1 rail bridging.
# Largest cells listed first so Innovus prefers them → fewer fragmented gaps → better DFM.
addFiller \
    -cell {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1} \
    -prefix FILL

# ── 11. Routing ──────────────────────────────────────────────
setNanoRouteMode -quiet -routeTopRoutingLayer 10
routeDesign -globalDetail

# ── 12. Post-Route Optimization ──────────────────────────────
setExtractRCMode -engine postRoute
extractRC

# [v2 NEW] timeDesign before each optDesign
timeDesign -postRoute
optDesign  -postRoute

timeDesign -postRoute -hold
optDesign  -postRoute -hold

# ── 13. Verification ─────────────────────────────────────────
verify_drc          -report mfn_frontend_top_v2.drc.rpt
verifyConnectivity  -type all -report mfn_frontend_top_v2.conn.rpt
verifyProcessAntenna -reportfile mfn_frontend_top_v2.antenna.rpt

# ── 14. Save ─────────────────────────────────────────────────
saveDesign   mfn_frontend_top_v2_final.enc
saveNetlist  mfn_frontend_top_v2_final_nophy.v
write_sdf    mfn_frontend_top_v2_final.sdf

report_timing > pnr_v2_timing.rep
report_power  > pnr_v2_power.rep

puts ""
puts "======================================================"
puts "  Innovus P&R v2 Finished — mfn_frontend_top"
puts "  v2 additions: CTS NDR (2W1S leaf / 2W2S trunk+VSS),"
puts "                timeDesign visibility, filler before route"
puts "  Reports : mfn_frontend_top_v2.{drc,conn,antenna}.rpt"
puts "           pnr_v2_timing.rep  pnr_v2_power.rep"
puts "  Netlist : mfn_frontend_top_v2_final_nophy.v"
puts "======================================================"
