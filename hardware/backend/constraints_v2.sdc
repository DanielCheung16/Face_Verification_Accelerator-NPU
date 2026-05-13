# ============================================================
# SDC Constraints v2 — MobileFaceNet Frontend
# Target: 83 MHz (12 ns period)
# Lowered from 100 MHz: post-route critical path through
# psum_mem write-enable decode + CLA-b + routing buffers
# was 11.461 ns at 100 MHz (WNS -0.922 ns).
# ============================================================

create_clock -name clk -period 12.0 [get_ports clk]
set_clock_uncertainty 0.1  [get_clocks clk]
set_clock_transition  0.1  [get_clocks clk]

set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.0 -clock clk [all_outputs]

set_false_path -from [get_ports rst_n]

set_driving_cell -lib_cell BUF_X1 [all_inputs]
set_load 0.05 [all_outputs]
