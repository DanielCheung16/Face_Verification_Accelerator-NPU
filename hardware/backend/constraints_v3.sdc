# ============================================================
# SDC Constraints v3 — MobileFaceNet Frontend (12×12 SA)
# Target: 83 MHz / 12 ns (NangateOpenCellLibrary / FreePDK45)
# v2 post-route WNS was +2.928 ns at 83 MHz (actual ~110 MHz headroom).
# v3 critical path: SRAM dout → psum adder (CLA-40) → SRAM din (same as v2).
# ============================================================

create_clock -name clk -period 12.0 [get_ports clk]
set_clock_uncertainty 0.1  [get_clocks clk]
set_clock_transition  0.1  [get_clocks clk]

set_input_delay  2.4 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.4 -clock clk [all_outputs]

set_false_path -from [get_ports rst_n]

set_driving_cell -lib_cell BUF_X1 [all_inputs]
set_load 0.05 [all_outputs]
