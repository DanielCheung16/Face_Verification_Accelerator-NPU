// Stream postprocess for spatial 3x3 outputs.
//
// One signed int32 psum enters per valid_i pulse. The module emits one int8
// value per valid_o pulse after the fixed pipeline latency. This stream shape
// fits the 3x3 PE array much better than the tile-shaped conv1x1 postprocess.
module small_output_process #(
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int DATA_W = 8,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,
    parameter int BIAS_SHIFT = 16,

    localparam int MODE_W = 3,
    localparam int VALUE_W = (BIAS_W > ACC_W) ? BIAS_W : ACC_W,
    localparam int PRODUCT_W = VALUE_W + MUL_W
) (
    input  logic clk,
    input  logic rst_n,

    input  logic signed [ACC_W-1:0] psum_i,
    input  logic                    valid_i,

    // Postprocess mode, matching the MobileFaceNet hardware/C-reference needs:
    //   0: bypass saturate int32 -> int8                 (bring-up/debug)
    //   1: requant                                       (QF_MODE_REQUANT)
    //   2: PReLU + requant                               (QF_MODE_PRELU)
    //   3: residual add + requant                         (QF_OP_RES_ADD)
    input  logic [MODE_W-1:0] mode_i,

    // Residual input is the stored int8 activation sign-extended to ACC_W.
    // It is re-centered and re-scaled before being added to psum+bias.
    input  logic                    residual_en_i,
    input  logic signed [ACC_W-1:0] residual_i,

    // Per-output-channel bias. This includes activation zero-point correction
    // and folded constants from the C/HW quantization model.
    input  logic signed [BIAS_W-1:0] bias_i,

    // Residual fixed-point scale:
    //   residual_scaled = round_shift((residual_i + residual_zero_point_i)
    //                                  * residual_multiplier_i,
    //                                  residual_shift_i)
    input  logic signed [MUL_W-1:0]  residual_multiplier_i,
    input  logic [SHIFT_W-1:0]       residual_shift_i,
    input  logic signed [BIAS_W-1:0] residual_zero_point_i,

    // Requant after bias/PReLU:
    //   round_shift(value * requant_multiplier_i,
    //               requant_shift_i + BIAS_SHIFT) + output_zero_point_i
    input  logic signed [MUL_W-1:0] requant_multiplier_i,
    input  logic [SHIFT_W-1:0]      requant_shift_i,
    input  logic signed [ACC_W-1:0] output_zero_point_i,

    // PReLU negative branch: round_shift(value * prelu_multiplier_i,
    //                                    prelu_shift_i)
    input  logic signed [MUL_W-1:0] prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]      prelu_shift_i,

    output logic signed [DATA_W-1:0] data_o,
    output logic                     valid_o
);
    localparam logic [MODE_W-1:0] MODE_REQUANT          = 3'd1;
    localparam logic [MODE_W-1:0] MODE_PRELU_REQUANT    = 3'd2;
    localparam logic [MODE_W-1:0] MODE_RESIDUAL_REQUANT = 3'd3;

    logic signed [VALUE_W-1:0] s0_main_value;
    logic signed [PRODUCT_W-1:0] s0_residual_product;
    logic [SHIFT_W-1:0] s0_residual_shift;
    logic s0_residual_active;
    logic [MODE_W-1:0] s0_mode;
    logic [SHIFT_W-1:0] s0_requant_shift;
    logic [SHIFT_W-1:0] s0_prelu_shift;
    logic signed [VALUE_W-1:0] s0_output_zero_point;
    logic signed [MUL_W-1:0] s0_requant_multiplier;
    logic signed [MUL_W-1:0] s0_prelu_multiplier;
    logic s0_valid;

    logic signed [VALUE_W-1:0] s1_value;
    logic [MODE_W-1:0] s1_mode;
    logic [SHIFT_W-1:0] s1_requant_shift;
    logic [SHIFT_W-1:0] s1_prelu_shift;
    logic signed [VALUE_W-1:0] s1_output_zero_point;
    logic signed [MUL_W-1:0] s1_requant_multiplier;
    logic signed [MUL_W-1:0] s1_prelu_multiplier;
    logic s1_valid;

    logic signed [VALUE_W-1:0] s2_value;
    logic signed [PRODUCT_W-1:0] s2_prelu_product;
    logic s2_do_prelu;
    logic [MODE_W-1:0] s2_mode;
    logic [SHIFT_W-1:0] s2_requant_shift;
    logic [SHIFT_W-1:0] s2_prelu_shift;
    logic signed [VALUE_W-1:0] s2_output_zero_point;
    logic signed [MUL_W-1:0] s2_requant_multiplier;
    logic s2_valid;

    logic signed [VALUE_W-1:0] s3_value;
    logic s3_requant_en;
    logic [MODE_W-1:0] s3_mode;
    logic [SHIFT_W-1:0] s3_requant_shift;
    logic signed [VALUE_W-1:0] s3_output_zero_point;
    logic signed [MUL_W-1:0] s3_requant_multiplier;
    logic s3_valid;

    logic signed [PRODUCT_W-1:0] s4_requant_product;
    logic [MODE_W-1:0] s4_mode;
    logic [SHIFT_W-1:0] s4_requant_shift;
    logic signed [VALUE_W-1:0] s4_output_zero_point;
    logic s4_valid;

    logic signed [VALUE_W-1:0] s5_value;
    logic s5_valid;

    logic signed [VALUE_W-1:0] main_value_w;
    logic signed [VALUE_W-1:0] residual_centered_w;
    logic [SHIFT_W-1:0] requant_total_shift_w;
    logic quant_mode_w;
    logic signed [VALUE_W-1:0] residual_shifted_w;
    logic signed [VALUE_W-1:0] residual_work_w;
    logic signed [VALUE_W-1:0] prelu_shifted_w;
    logic signed [VALUE_W-1:0] requant_shifted_w;
    logic signed [VALUE_W-1:0] final_value_w;
    logic signed [PRODUCT_W-1:0] residual_round_offset_w;
    logic signed [PRODUCT_W-1:0] prelu_round_offset_w;
    logic signed [PRODUCT_W-1:0] requant_round_offset_w;
    logic signed [PRODUCT_W-1:0] residual_product_rounded_w;
    logic signed [PRODUCT_W-1:0] prelu_product_rounded_w;
    logic signed [PRODUCT_W-1:0] requant_product_rounded_w;
    logic residual_active_w;

    function automatic logic signed [DATA_W-1:0] sat_int8(input logic signed [VALUE_W-1:0] value);
        logic signed [VALUE_W-1:0] max_v;
        logic signed [VALUE_W-1:0] min_v;
        begin
            max_v = VALUE_W'(127);
            min_v = -VALUE_W'(128);
            if (value > max_v) begin
                sat_int8 = DATA_W'(8'sh7f);
            end else if (value < min_v) begin
                sat_int8 = DATA_W'(8'sh80);
            end else begin
                sat_int8 = value[DATA_W-1:0];
            end
        end
    endfunction

    assign residual_active_w = residual_en_i || (mode_i == MODE_RESIDUAL_REQUANT);
    assign quant_mode_w = (mode_i == MODE_REQUANT) ||
                          (mode_i == MODE_PRELU_REQUANT) ||
                          (mode_i == MODE_RESIDUAL_REQUANT);
    // Match qface C model: accumulator is promoted into the QBIAS_SHIFT
    // domain before adding folded bias. Bypass mode keeps the raw psum path for
    // bring-up tests and raw-accumulator debug.
    assign main_value_w = quant_mode_w ? ((VALUE_W'(psum_i) <<< BIAS_SHIFT) + VALUE_W'(bias_i)) :
                                         VALUE_W'(psum_i);
    assign residual_centered_w = VALUE_W'(residual_i) + VALUE_W'(residual_zero_point_i);
    assign requant_total_shift_w = requant_shift_i + SHIFT_W'(BIAS_SHIFT);

    // Match the C reference round_shift_i64(): (value + (1 << (shift-1))) >> shift.
    assign residual_round_offset_w = (s0_residual_shift == '0) ? '0 :
                                     (PRODUCT_W'(1) <<< (s0_residual_shift - SHIFT_W'(1)));
    assign prelu_round_offset_w = (s2_prelu_shift == '0) ? '0 :
                                  (PRODUCT_W'(1) <<< (s2_prelu_shift - SHIFT_W'(1)));
    assign requant_round_offset_w = (s4_requant_shift == '0) ? '0 :
                                    (PRODUCT_W'(1) <<< (s4_requant_shift - SHIFT_W'(1)));
    assign residual_product_rounded_w = s0_residual_product + residual_round_offset_w;
    assign prelu_product_rounded_w = s2_prelu_product + prelu_round_offset_w;
    assign requant_product_rounded_w = s4_requant_product + requant_round_offset_w;
    assign residual_shifted_w = VALUE_W'(residual_product_rounded_w >>> s0_residual_shift);
    assign residual_work_w = ((s0_mode == MODE_REQUANT) ||
                              (s0_mode == MODE_PRELU_REQUANT) ||
                              (s0_mode == MODE_RESIDUAL_REQUANT)) ?
                             (residual_shifted_w <<< BIAS_SHIFT) :
                             residual_shifted_w;
    assign prelu_shifted_w = VALUE_W'(prelu_product_rounded_w >>> s2_prelu_shift);
    assign requant_shifted_w = VALUE_W'(requant_product_rounded_w >>> s4_requant_shift);
    assign final_value_w = requant_shifted_w + s4_output_zero_point;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_main_value <= '0;
            s0_residual_product <= '0;
            s0_residual_shift <= '0;
            s0_residual_active <= 1'b0;
            s0_mode <= '0;
            s0_requant_shift <= '0;
            s0_prelu_shift <= '0;
            s0_output_zero_point <= '0;
            s0_requant_multiplier <= '0;
            s0_prelu_multiplier <= '0;
            s0_valid <= 1'b0;

            s1_value <= '0;
            s1_mode <= '0;
            s1_requant_shift <= '0;
            s1_prelu_shift <= '0;
            s1_output_zero_point <= '0;
            s1_requant_multiplier <= '0;
            s1_prelu_multiplier <= '0;
            s1_valid <= 1'b0;

            s2_value <= '0;
            s2_prelu_product <= '0;
            s2_do_prelu <= 1'b0;
            s2_mode <= '0;
            s2_requant_shift <= '0;
            s2_prelu_shift <= '0;
            s2_output_zero_point <= '0;
            s2_requant_multiplier <= '0;
            s2_valid <= 1'b0;

            s3_value <= '0;
            s3_requant_en <= 1'b0;
            s3_mode <= '0;
            s3_requant_shift <= '0;
            s3_output_zero_point <= '0;
            s3_requant_multiplier <= '0;
            s3_valid <= 1'b0;

            s4_requant_product <= '0;
            s4_mode <= '0;
            s4_requant_shift <= '0;
            s4_output_zero_point <= '0;
            s4_valid <= 1'b0;

            s5_value <= '0;
            s5_valid <= 1'b0;
            data_o <= '0;
            valid_o <= 1'b0;
        end else begin
            // Stage 0: register psum+bias and start residual fixed-point scale.
            s0_main_value <= main_value_w;
            if (residual_active_w) begin
                s0_residual_product <= residual_centered_w * residual_multiplier_i;
            end else begin
                s0_residual_product <= '0;
            end
            s0_residual_shift <= residual_shift_i;
            s0_residual_active <= residual_active_w;
            s0_mode <= mode_i;
            s0_requant_shift <= requant_total_shift_w;
            s0_prelu_shift <= prelu_shift_i;
            s0_output_zero_point <= VALUE_W'(output_zero_point_i);
            s0_requant_multiplier <= requant_multiplier_i;
            s0_prelu_multiplier <= prelu_multiplier_i;
            s0_valid <= valid_i;

            // Stage 1: finish residual scale and add it into psum+bias.
            if (s0_residual_active) begin
                s1_value <= s0_main_value + residual_work_w;
            end else begin
                s1_value <= s0_main_value;
            end
            s1_mode <= s0_mode;
            s1_requant_shift <= s0_requant_shift;
            s1_prelu_shift <= s0_prelu_shift;
            s1_output_zero_point <= s0_output_zero_point;
            s1_requant_multiplier <= s0_requant_multiplier;
            s1_prelu_multiplier <= s0_prelu_multiplier;
            s1_valid <= s0_valid;

            // Stage 2: PReLU negative-branch multiply. Non-PReLU modes bypass.
            s2_mode <= s1_mode;
            s2_requant_shift <= s1_requant_shift;
            s2_prelu_shift <= s1_prelu_shift;
            s2_output_zero_point <= s1_output_zero_point;
            s2_requant_multiplier <= s1_requant_multiplier;
            s2_valid <= s1_valid;
            s2_do_prelu <= (s1_mode == MODE_PRELU_REQUANT) && (s1_value < VALUE_W'(0));
            if ((s1_mode == MODE_PRELU_REQUANT) && (s1_value < VALUE_W'(0))) begin
                s2_prelu_product <= s1_value * s1_prelu_multiplier;
            end else begin
                s2_prelu_product <= {{MUL_W{s1_value[VALUE_W-1]}}, s1_value};
            end
            s2_value <= s1_value;

            // Stage 3: finish optional PReLU negative branch.
            s3_mode <= s2_mode;
            s3_requant_shift <= s2_requant_shift;
            s3_output_zero_point <= s2_output_zero_point;
            s3_requant_multiplier <= s2_requant_multiplier;
            s3_valid <= s2_valid;
            s3_requant_en <= (s2_mode == MODE_REQUANT) ||
                             (s2_mode == MODE_RESIDUAL_REQUANT) ||
                             (s2_mode == MODE_PRELU_REQUANT);
            if (s2_do_prelu) begin
                s3_value <= prelu_shifted_w;
            end else begin
                s3_value <= s2_value;
            end

            // Stage 4: requant multiply after residual/PReLU value selection.
            s4_mode <= s3_mode;
            s4_requant_shift <= s3_requant_shift;
            s4_output_zero_point <= s3_output_zero_point;
            s4_valid <= s3_valid;
            if (s3_requant_en) begin
                s4_requant_product <= s3_value * s3_requant_multiplier;
            end else begin
                s4_requant_product <= {{MUL_W{s3_value[VALUE_W-1]}}, s3_value};
            end

            // Stage 5: shift/add zero-point or bypass.
            if ((s4_mode == MODE_REQUANT) ||
                (s4_mode == MODE_RESIDUAL_REQUANT) ||
                (s4_mode == MODE_PRELU_REQUANT)) begin
                s5_value <= final_value_w;
            end else begin
                s5_value <= VALUE_W'(s4_requant_product);
            end
            s5_valid <= s4_valid;

            data_o <= sat_int8(s5_value);
            valid_o <= s5_valid;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ACC_W != 32 || DATA_W != 8) begin
            $fatal(1, "small_output_process currently expects ACC_W=32 and DATA_W=8");
        end
    end
`endif
endmodule
