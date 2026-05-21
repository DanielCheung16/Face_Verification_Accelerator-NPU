# ============================================================
# SDC Constraints v3 — MobileFaceNet Frontend (12×12 SA)
# Target: 200 MHz (5.0 ns period) — note §35 Stage 3 max-push.
#   At 5.75 ns post-route, slack was +0.565 ns with critical path
#     u_act_buf/act_out_reg → CSA tree (mult fused) → u_sa/row_dot_reg
#   (5.503 ns data).  Pushing to 5.0 ns leaves ~0 ns headroom — Stage 3
#   has been the bound; if this fails, Stage 3.5 (per-product register)
#   would be the next step.
# ============================================================

create_clock -name clk -period 5.0 [get_ports clk]
set_clock_uncertainty 0.1  [get_clocks clk]
set_clock_transition  0.1  [get_clocks clk]

set_input_delay  1.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 1.0 -clock clk [all_outputs]

set_false_path -from [get_ports rst_n]

set_driving_cell -lib_cell BUF_X1 [all_inputs]
set_load 0.05 [all_outputs]
