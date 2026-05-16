// Stream postprocess for spatial 3x3 outputs.
//
// One signed int32 psum enters per valid_i pulse. The module emits one int8
// value per valid_o pulse after the fixed pipeline latency. This stream shape
// fits the 3x3 PE array much better than the tile-shaped conv1x1 postprocess.
module small_output_process #(
    parameter int ACC_W = 32,
    parameter int DATA_W = 8,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,

    localparam int MODE_W = 3
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

    // Optional residual stream. The producer must align residual_i with psum_i.
    input  logic                    residual_en_i,
    input  logic signed [ACC_W-1:0] residual_i,

    // Requant: ((value * requant_multiplier_i) >>> requant_shift_i) + output_zero_point_i
    input  logic signed [MUL_W-1:0] requant_multiplier_i,
    input  logic [SHIFT_W-1:0]      requant_shift_i,
    input  logic signed [ACC_W-1:0] output_zero_point_i,

    // PReLU negative branch: (value * prelu_multiplier_i) >>> prelu_shift_i
    input  logic signed [MUL_W-1:0] prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]      prelu_shift_i,

    output logic signed [DATA_W-1:0] data_o,
    output logic                     valid_o
);
    localparam logic [MODE_W-1:0] MODE_BYPASS          = 3'd0;
    localparam logic [MODE_W-1:0] MODE_REQUANT         = 3'd1;
    localparam logic [MODE_W-1:0] MODE_PRELU_REQUANT   = 3'd2;
    localparam logic [MODE_W-1:0] MODE_RESIDUAL_REQUANT = 3'd3;

    localparam int PRODUCT_W = ACC_W + MUL_W;

    logic signed [ACC_W-1:0] s0_value;
    logic [MODE_W-1:0] s0_mode;
    logic [SHIFT_W-1:0] s0_requant_shift;
    logic [SHIFT_W-1:0] s0_prelu_shift;
    logic signed [ACC_W-1:0] s0_output_zero_point;
    logic signed [MUL_W-1:0] s0_requant_multiplier;
    logic signed [MUL_W-1:0] s0_prelu_multiplier;
    logic s0_valid;

    logic signed [ACC_W-1:0] s1_value;
    logic signed [PRODUCT_W-1:0] s1_prelu_product;
    logic s1_do_prelu;
    logic [MODE_W-1:0] s1_mode;
    logic [SHIFT_W-1:0] s1_requant_shift;
    logic [SHIFT_W-1:0] s1_prelu_shift;
    logic signed [ACC_W-1:0] s1_output_zero_point;
    logic signed [MUL_W-1:0] s1_requant_multiplier;
    logic s1_valid;

    logic signed [ACC_W-1:0] s2_value;
    logic s2_requant_en;
    logic [MODE_W-1:0] s2_mode;
    logic [SHIFT_W-1:0] s2_requant_shift;
    logic signed [ACC_W-1:0] s2_output_zero_point;
    logic signed [MUL_W-1:0] s2_requant_multiplier;
    logic s2_valid;

    logic signed [PRODUCT_W-1:0] s3_requant_product;
    logic [MODE_W-1:0] s3_mode;
    logic [SHIFT_W-1:0] s3_requant_shift;
    logic signed [ACC_W-1:0] s3_output_zero_point;
    logic s3_valid;

    logic signed [ACC_W-1:0] s4_value;
    logic s4_valid;

    logic signed [ACC_W-1:0] residual_sum_w;
    logic signed [ACC_W-1:0] prelu_shifted_w;
    logic signed [ACC_W-1:0] requant_shifted_w;
    logic signed [ACC_W-1:0] final_value_w;
    logic signed [PRODUCT_W-1:0] prelu_round_offset_w;
    logic signed [PRODUCT_W-1:0] requant_round_offset_w;
    logic signed [PRODUCT_W-1:0] prelu_product_rounded_w;
    logic signed [PRODUCT_W-1:0] requant_product_rounded_w;
    logic residual_active_w;

    function automatic logic signed [DATA_W-1:0] sat_int8(input logic signed [ACC_W-1:0] value);
        logic signed [ACC_W-1:0] max_v;
        logic signed [ACC_W-1:0] min_v;
        begin
            max_v = ACC_W'(127);
            min_v = -ACC_W'(128);
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
    assign residual_sum_w = residual_active_w ? (psum_i + residual_i) : psum_i;

    // Match the C reference round_shift_i64(): (value + (1 << (shift-1))) >> shift.
    // These are outside helper functions so multiply/shift paths remain visible
    // in timing reports and easy to pipeline further.
    assign prelu_round_offset_w = (s1_prelu_shift == '0) ? '0 :
                                  (PRODUCT_W'(1) <<< (s1_prelu_shift - SHIFT_W'(1)));
    assign requant_round_offset_w = (s3_requant_shift == '0) ? '0 :
                                    (PRODUCT_W'(1) <<< (s3_requant_shift - SHIFT_W'(1)));
    assign prelu_product_rounded_w = s1_prelu_product + prelu_round_offset_w;
    assign requant_product_rounded_w = s3_requant_product + requant_round_offset_w;
    assign prelu_shifted_w = ACC_W'(prelu_product_rounded_w >>> s1_prelu_shift);
    assign requant_shifted_w = ACC_W'(requant_product_rounded_w >>> s3_requant_shift);
    assign final_value_w = requant_shifted_w + s3_output_zero_point;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_value <= '0;
            s0_mode <= '0;
            s0_requant_shift <= '0;
            s0_prelu_shift <= '0;
            s0_output_zero_point <= '0;
            s0_requant_multiplier <= '0;
            s0_prelu_multiplier <= '0;
            s0_valid <= 1'b0;

            s1_value <= '0;
            s1_prelu_product <= '0;
            s1_do_prelu <= 1'b0;
            s1_mode <= '0;
            s1_requant_shift <= '0;
            s1_prelu_shift <= '0;
            s1_output_zero_point <= '0;
            s1_requant_multiplier <= '0;
            s1_valid <= 1'b0;

            s2_value <= '0;
            s2_requant_en <= 1'b0;
            s2_mode <= '0;
            s2_requant_shift <= '0;
            s2_output_zero_point <= '0;
            s2_requant_multiplier <= '0;
            s2_valid <= 1'b0;

            s3_requant_product <= '0;
            s3_mode <= '0;
            s3_requant_shift <= '0;
            s3_output_zero_point <= '0;
            s3_valid <= 1'b0;

            s4_value <= '0;
            s4_valid <= 1'b0;
            data_o <= '0;
            valid_o <= 1'b0;
        end else begin
            // Stage 0: optional residual add. MobileFaceNet uses PReLU, not a
            // separate ReLU postprocess, so there is no ReLU mode here.
            s0_value <= residual_sum_w;
            s0_mode <= mode_i;
            s0_requant_shift <= requant_shift_i;
            s0_prelu_shift <= prelu_shift_i;
            s0_output_zero_point <= output_zero_point_i;
            s0_requant_multiplier <= requant_multiplier_i;
            s0_prelu_multiplier <= prelu_multiplier_i;
            s0_valid <= valid_i;

            // Stage 1: PReLU negative-branch multiply. Non-PReLU modes bypass.
            s1_mode <= s0_mode;
            s1_requant_shift <= s0_requant_shift;
            s1_prelu_shift <= s0_prelu_shift;
            s1_output_zero_point <= s0_output_zero_point;
            s1_requant_multiplier <= s0_requant_multiplier;
            s1_valid <= s0_valid;
            s1_do_prelu <= (s0_mode == MODE_PRELU_REQUANT) && (s0_value < ACC_W'(0));
            if ((s0_mode == MODE_PRELU_REQUANT) && (s0_value < ACC_W'(0))) begin
                s1_prelu_product <= s0_value * s0_prelu_multiplier;
            end else begin
                s1_prelu_product <= {{MUL_W{s0_value[ACC_W-1]}}, s0_value};
            end
            s1_value <= s0_value;

            // Stage 2: finish the optional PReLU negative branch.
            s2_mode <= s1_mode;
            s2_requant_shift <= s1_requant_shift;
            s2_output_zero_point <= s1_output_zero_point;
            s2_requant_multiplier <= s1_requant_multiplier;
            s2_valid <= s1_valid;
            s2_requant_en <= (s1_mode == MODE_REQUANT) ||
                             (s1_mode == MODE_RESIDUAL_REQUANT) ||
                             (s1_mode == MODE_PRELU_REQUANT);
            if (s1_do_prelu) begin
                s2_value <= prelu_shifted_w;
            end else begin
                s2_value <= s1_value;
            end

            // Stage 3: requant multiply after PReLU value selection.
            s3_mode <= s2_mode;
            s3_requant_shift <= s2_requant_shift;
            s3_output_zero_point <= s2_output_zero_point;
            s3_valid <= s2_valid;
            if (s2_requant_en) begin
                s3_requant_product <= s2_value * s2_requant_multiplier;
            end else begin
                s3_requant_product <= {{MUL_W{s2_value[ACC_W-1]}}, s2_value};
            end

            // Stage 4: shift/add zero-point or bypass.
            if ((s3_mode == MODE_REQUANT) ||
                (s3_mode == MODE_RESIDUAL_REQUANT) ||
                (s3_mode == MODE_PRELU_REQUANT)) begin
                s4_value <= final_value_w;
            end else begin
                s4_value <= ACC_W'(s3_requant_product);
            end
            s4_valid <= s3_valid;

            data_o <= sat_int8(s4_value);
            valid_o <= s4_valid;
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
