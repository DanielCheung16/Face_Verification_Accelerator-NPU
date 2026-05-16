# ============================================================
# SDC Constraints v2 — MobileFaceNet Frontend
# Target: 125 MHz (8 ns period)
# Post-route critical path (SRAM dout → CLA → SRAM din)
# at 100 MHz WNS was +1.848 ns; pushing to 125 MHz for headroom.
# ============================================================

create_clock -name clk -period 8.0 [get_ports clk]
set_clock_uncertainty 0.1  [get_clocks clk]
set_clock_transition  0.1  [get_clocks clk]

set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.0 -clock clk [all_outputs]

set_false_path -from [get_ports rst_n]

set_driving_cell -lib_cell BUF_X1 [all_inputs]
set_load 0.05 [all_outputs]
