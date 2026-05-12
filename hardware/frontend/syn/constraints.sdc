# ============================================================
# SDC Constraints — MobileFaceNet Frontend
# Target: 100 MHz (10 ns period)
# ============================================================

# Primary clock
create_clock -name clk -period 10.0 [get_ports clk]
set_clock_uncertainty 0.1  [get_clocks clk]
set_clock_transition  0.1  [get_clocks clk]

# Input delays (20% of period = 2 ns)
set_input_delay 2.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]

# Output delays (20% of period = 2 ns)
set_output_delay 2.0 -clock clk [all_outputs]

# Async reset: no timing required
set_false_path -from [get_ports rst_n]

# Drive strength / load (use typical library defaults)
set_driving_cell -lib_cell BUF_X1 [all_inputs]
set_load 0.05 [all_outputs]
