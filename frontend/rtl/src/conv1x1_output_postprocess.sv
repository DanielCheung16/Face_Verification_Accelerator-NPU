`include "layer_defs.svh"

// Row-streamed conv1x1 postprocess. One row of LANES outputs enters per valid_i
// pulse. The residual pre-add is registered before the multiplier so the row
// select mux in conv1x1_wb is not on the same timing path as the DSP chain.
module conv1x1_output_postprocess #(
    parameter int LANES = 16,
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int BIAS_SHIFT = 16,
    parameter int OUT_W = 8,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,

    localparam int VALUE_W = BIAS_W,
    localparam int PRODUCT_W = VALUE_W + MULT_W
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    input  logic                       valid_i,
    input  logic                       lane_valid_i [LANES],
    input  logic signed [ACC_W-1:0]    acc_i        [LANES],
    input  logic [1:0]                 mode_i,

    input  logic signed [BIAS_W-1:0]   bias_i       [LANES],
    input  logic signed [MULT_W-1:0]   multiplier_i [LANES],
    input  logic [SHIFT_W-1:0]         shift_i      [LANES],
    input  logic signed [OUT_W-1:0]    zero_point_i [LANES],
    input  logic signed [MULT_W-1:0]   prelu_multiplier_i [LANES],
    input  logic [SHIFT_W-1:0]         prelu_shift_i      [LANES],
    input  logic signed [ACC_W-1:0]    residual_i [LANES],
    input  logic signed [MULT_W-1:0]   residual_multiplier_i [LANES],
    input  logic [SHIFT_W-1:0]         residual_shift_i [LANES],
    input  logic signed [ACC_W-1:0]    residual_zero_point_i [LANES],

    output logic                       valid_o,
    output logic                       lane_valid_o [LANES],
    output logic signed [OUT_W-1:0]    data_o       [LANES]
);
    localparam logic signed [VALUE_W-1:0] OUT_MAX = VALUE_W'(127);
    localparam logic signed [VALUE_W-1:0] OUT_MIN = -VALUE_W'(128);

    logic signed [VALUE_W-1:0] s0_main_value [LANES];
    logic signed [VALUE_W-1:0] s0_residual_centered [LANES];
    logic signed [MULT_W-1:0]  s0_residual_multiplier [LANES];
    logic [SHIFT_W-1:0]        s0_residual_shift [LANES];
    logic signed [MULT_W-1:0]  s0_requant_multiplier [LANES];
    logic [SHIFT_W-1:0]        s0_requant_shift [LANES];
    logic signed [OUT_W-1:0]   s0_zero_point [LANES];
    logic signed [MULT_W-1:0]  s0_prelu_multiplier [LANES];
    logic [SHIFT_W-1:0]        s0_prelu_shift [LANES];
    logic [1:0]                s0_mode;
    logic                      s0_lane_valid [LANES];
    logic                      s0_valid;

    logic signed [VALUE_W-1:0]   s1_main_value [LANES];
    logic signed [PRODUCT_W-1:0] s1_residual_product [LANES];
    logic [SHIFT_W-1:0]          s1_residual_shift [LANES];
    logic signed [MULT_W-1:0]    s1_requant_multiplier [LANES];
    logic [SHIFT_W-1:0]          s1_requant_shift [LANES];
    logic signed [OUT_W-1:0]     s1_zero_point [LANES];
    logic signed [MULT_W-1:0]    s1_prelu_multiplier [LANES];
    logic [SHIFT_W-1:0]          s1_prelu_shift [LANES];
    logic [1:0]                  s1_mode;
    logic                        s1_lane_valid [LANES];
    logic                        s1_valid;

    logic signed [VALUE_W-1:0] s2_value [LANES];
    logic signed [MULT_W-1:0]  s2_requant_multiplier [LANES];
    logic [SHIFT_W-1:0]        s2_requant_shift [LANES];
    logic signed [OUT_W-1:0]   s2_zero_point [LANES];
    logic signed [MULT_W-1:0]  s2_prelu_multiplier [LANES];
    logic [SHIFT_W-1:0]        s2_prelu_shift [LANES];
    logic [1:0]                s2_mode;
    logic                      s2_lane_valid [LANES];
    logic                      s2_valid;

    logic signed [VALUE_W-1:0]   s3_value [LANES];
    logic signed [PRODUCT_W-1:0] s3_prelu_product [LANES];
    logic signed [MULT_W-1:0]    s3_requant_multiplier [LANES];
    logic [SHIFT_W-1:0]          s3_requant_shift [LANES];
    logic signed [OUT_W-1:0]     s3_zero_point [LANES];
    logic [SHIFT_W-1:0]          s3_prelu_shift [LANES];
    logic                        s3_do_prelu [LANES];
    logic                        s3_lane_valid [LANES];
    logic                        s3_valid;

    logic signed [VALUE_W-1:0] s4_value [LANES];
    logic signed [MULT_W-1:0]  s4_requant_multiplier [LANES];
    logic [SHIFT_W-1:0]        s4_requant_shift [LANES];
    logic signed [OUT_W-1:0]   s4_zero_point [LANES];
    logic                      s4_lane_valid [LANES];
    logic                      s4_valid;

    logic signed [PRODUCT_W-1:0] s5_requant_product [LANES];
    logic [SHIFT_W-1:0]          s5_requant_shift [LANES];
    logic signed [OUT_W-1:0]     s5_zero_point [LANES];
    logic                        s5_lane_valid [LANES];
    logic                        s5_valid;

    logic signed [VALUE_W-1:0] s6_requant_shifted [LANES];
    logic signed [OUT_W-1:0]   s6_zero_point [LANES];
    logic                      s6_lane_valid [LANES];
    logic                      s6_valid;

    logic signed [VALUE_W-1:0] s7_value [LANES];
    logic                      s7_lane_valid [LANES];
    logic                      s7_valid;

    logic signed [PRODUCT_W-1:0] residual_round_offset_w [LANES];
    logic signed [PRODUCT_W-1:0] prelu_round_offset_w [LANES];
    logic signed [PRODUCT_W-1:0] requant_round_offset_w [LANES];
    logic signed [VALUE_W-1:0] residual_shifted_w [LANES];
    logic signed [VALUE_W-1:0] prelu_shifted_w [LANES];
    logic signed [VALUE_W-1:0] requant_shifted_w [LANES];
    logic signed [VALUE_W-1:0] final_value_w [LANES];

    function automatic logic signed [VALUE_W-1:0] sext_acc(input logic signed [ACC_W-1:0] value);
        begin
            sext_acc = {{(VALUE_W-ACC_W){value[ACC_W-1]}}, value};
        end
    endfunction

    function automatic logic signed [VALUE_W-1:0] sext_out(input logic signed [OUT_W-1:0] value);
        begin
            sext_out = {{(VALUE_W-OUT_W){value[OUT_W-1]}}, value};
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] multiply_value_mult(
        input logic signed [VALUE_W-1:0] value,
        input logic signed [MULT_W-1:0] multiplier
    );
        begin
            multiply_value_mult = $signed(value) * $signed(multiplier);
        end
    endfunction

    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            residual_round_offset_w[i] = (s1_residual_shift[i] == '0) ? '0 :
                                         (PRODUCT_W'(1) <<< (s1_residual_shift[i] - SHIFT_W'(1)));
            prelu_round_offset_w[i] = (s3_prelu_shift[i] == '0) ? '0 :
                                      (PRODUCT_W'(1) <<< (s3_prelu_shift[i] - SHIFT_W'(1)));
            requant_round_offset_w[i] = (s5_requant_shift[i] == '0) ? '0 :
                                        (PRODUCT_W'(1) <<< (s5_requant_shift[i] - SHIFT_W'(1)));

            residual_shifted_w[i] = $signed(s1_residual_product[i] + residual_round_offset_w[i]) >>>
                                    s1_residual_shift[i];
            prelu_shifted_w[i] = $signed(s3_prelu_product[i] + prelu_round_offset_w[i]) >>>
                                 s3_prelu_shift[i];
            requant_shifted_w[i] = $signed(s5_requant_product[i] + requant_round_offset_w[i]) >>>
                                   s5_requant_shift[i];
            final_value_w[i] = s6_requant_shifted[i] + sext_out(s6_zero_point[i]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
            s5_valid <= 1'b0;
            s6_valid <= 1'b0;
            s7_valid <= 1'b0;
            valid_o <= 1'b0;
            s0_mode <= MODE_REQUANT;
            s1_mode <= MODE_REQUANT;
            s2_mode <= MODE_REQUANT;

            for (int i = 0; i < LANES; i++) begin
                s0_main_value[i] <= '0;
                s0_residual_centered[i] <= '0;
                s0_residual_multiplier[i] <= '0;
                s0_residual_shift[i] <= '0;
                s0_requant_multiplier[i] <= '0;
                s0_requant_shift[i] <= '0;
                s0_zero_point[i] <= '0;
                s0_prelu_multiplier[i] <= '0;
                s0_prelu_shift[i] <= '0;
                s0_lane_valid[i] <= 1'b0;

                s1_main_value[i] <= '0;
                s1_residual_product[i] <= '0;
                s1_residual_shift[i] <= '0;
                s1_requant_multiplier[i] <= '0;
                s1_requant_shift[i] <= '0;
                s1_zero_point[i] <= '0;
                s1_prelu_multiplier[i] <= '0;
                s1_prelu_shift[i] <= '0;
                s1_lane_valid[i] <= 1'b0;

                s2_value[i] <= '0;
                s2_requant_multiplier[i] <= '0;
                s2_requant_shift[i] <= '0;
                s2_zero_point[i] <= '0;
                s2_prelu_multiplier[i] <= '0;
                s2_prelu_shift[i] <= '0;
                s2_lane_valid[i] <= 1'b0;

                s3_value[i] <= '0;
                s3_prelu_product[i] <= '0;
                s3_requant_multiplier[i] <= '0;
                s3_requant_shift[i] <= '0;
                s3_zero_point[i] <= '0;
                s3_prelu_shift[i] <= '0;
                s3_do_prelu[i] <= 1'b0;
                s3_lane_valid[i] <= 1'b0;

                s4_value[i] <= '0;
                s4_requant_multiplier[i] <= '0;
                s4_requant_shift[i] <= '0;
                s4_zero_point[i] <= '0;
                s4_lane_valid[i] <= 1'b0;

                s5_requant_product[i] <= '0;
                s5_requant_shift[i] <= '0;
                s5_zero_point[i] <= '0;
                s5_lane_valid[i] <= 1'b0;

                s6_requant_shifted[i] <= '0;
                s6_zero_point[i] <= '0;
                s6_lane_valid[i] <= 1'b0;

                s7_value[i] <= '0;
                s7_lane_valid[i] <= 1'b0;
                lane_valid_o[i] <= 1'b0;
                data_o[i] <= '0;
            end
        end else if (run_en_i) begin
            s0_valid <= valid_i;
            s0_mode <= mode_i;
            for (int i = 0; i < LANES; i++) begin
                s0_main_value[i] <= (sext_acc(acc_i[i]) <<< BIAS_SHIFT) + bias_i[i];
                s0_residual_centered[i] <= sext_acc(residual_i[i]) + sext_acc(residual_zero_point_i[i]);
                s0_residual_multiplier[i] <= residual_multiplier_i[i];
                s0_residual_shift[i] <= residual_shift_i[i];
                s0_requant_multiplier[i] <= multiplier_i[i];
                s0_requant_shift[i] <= shift_i[i] + SHIFT_W'(BIAS_SHIFT);
                s0_zero_point[i] <= zero_point_i[i];
                s0_prelu_multiplier[i] <= prelu_multiplier_i[i];
                s0_prelu_shift[i] <= prelu_shift_i[i];
                s0_lane_valid[i] <= lane_valid_i[i];
            end

            s1_valid <= s0_valid;
            s1_mode <= s0_mode;
            for (int i = 0; i < LANES; i++) begin
                s1_main_value[i] <= s0_main_value[i];
                s1_residual_product[i] <= (s0_mode == MODE_RESIDUAL) ?
                    multiply_value_mult(s0_residual_centered[i], s0_residual_multiplier[i]) : '0;
                s1_residual_shift[i] <= s0_residual_shift[i];
                s1_requant_multiplier[i] <= s0_requant_multiplier[i];
                s1_requant_shift[i] <= s0_requant_shift[i];
                s1_zero_point[i] <= s0_zero_point[i];
                s1_prelu_multiplier[i] <= s0_prelu_multiplier[i];
                s1_prelu_shift[i] <= s0_prelu_shift[i];
                s1_lane_valid[i] <= s0_lane_valid[i];
            end

            s2_valid <= s1_valid;
            s2_mode <= s1_mode;
            for (int i = 0; i < LANES; i++) begin
                s2_value[i] <= (s1_mode == MODE_RESIDUAL) ?
                    (s1_main_value[i] + (residual_shifted_w[i] <<< BIAS_SHIFT)) :
                    s1_main_value[i];
                s2_requant_multiplier[i] <= s1_requant_multiplier[i];
                s2_requant_shift[i] <= s1_requant_shift[i];
                s2_zero_point[i] <= s1_zero_point[i];
                s2_prelu_multiplier[i] <= s1_prelu_multiplier[i];
                s2_prelu_shift[i] <= s1_prelu_shift[i];
                s2_lane_valid[i] <= s1_lane_valid[i];
            end

            s3_valid <= s2_valid;
            for (int i = 0; i < LANES; i++) begin
                s3_value[i] <= s2_value[i];
                s3_requant_multiplier[i] <= s2_requant_multiplier[i];
                s3_requant_shift[i] <= s2_requant_shift[i];
                s3_zero_point[i] <= s2_zero_point[i];
                s3_prelu_shift[i] <= s2_prelu_shift[i];
                s3_do_prelu[i] <= (s2_mode == MODE_PRELU) && s2_value[i][VALUE_W-1];
                s3_prelu_product[i] <= ((s2_mode == MODE_PRELU) && s2_value[i][VALUE_W-1]) ?
                    multiply_value_mult(s2_value[i], s2_prelu_multiplier[i]) : '0;
                s3_lane_valid[i] <= s2_lane_valid[i];
            end

            s4_valid <= s3_valid;
            for (int i = 0; i < LANES; i++) begin
                s4_value[i] <= s3_do_prelu[i] ? prelu_shifted_w[i] : s3_value[i];
                s4_requant_multiplier[i] <= s3_requant_multiplier[i];
                s4_requant_shift[i] <= s3_requant_shift[i];
                s4_zero_point[i] <= s3_zero_point[i];
                s4_lane_valid[i] <= s3_lane_valid[i];
            end

            s5_valid <= s4_valid;
            for (int i = 0; i < LANES; i++) begin
                s5_requant_product[i] <= multiply_value_mult(s4_value[i], s4_requant_multiplier[i]);
                s5_requant_shift[i] <= s4_requant_shift[i];
                s5_zero_point[i] <= s4_zero_point[i];
                s5_lane_valid[i] <= s4_lane_valid[i];
            end

            s6_valid <= s5_valid;
            for (int i = 0; i < LANES; i++) begin
                s6_requant_shifted[i] <= requant_shifted_w[i];
                s6_zero_point[i] <= s5_zero_point[i];
                s6_lane_valid[i] <= s5_lane_valid[i];
            end

            // Keep the wide requant shift and the final zero-point add in
            // separate stages to avoid a long carry/shifter/carry chain.
            s7_valid <= s6_valid;
            for (int i = 0; i < LANES; i++) begin
                s7_value[i] <= final_value_w[i];
                s7_lane_valid[i] <= s6_lane_valid[i];
            end

            valid_o <= s7_valid;
            for (int i = 0; i < LANES; i++) begin
                lane_valid_o[i] <= s7_lane_valid[i];
                if (s7_value[i] > OUT_MAX) begin
                    data_o[i] <= OUT_W'(8'sh7f);
                end else if (s7_value[i] < OUT_MIN) begin
                    data_o[i] <= OUT_W'(8'sh80);
                end else begin
                    data_o[i] <= s7_value[i][OUT_W-1:0];
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (VALUE_W < ACC_W) begin
            $fatal(1, "conv1x1_output_postprocess requires BIAS_W >= ACC_W");
        end
    end
`endif
endmodule
