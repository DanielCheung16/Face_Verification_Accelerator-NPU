`include "layer_defs.svh"

module conv1x1_output_postprocess #(
    parameter int ROW = 14,
    parameter int COL = 16,
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int BIAS_SHIFT = 16,
    parameter int OUT_W = 8,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,
    parameter int DIM_W = 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,
    input  logic valid_tile_i,

    input  logic [DIM_W-1:0] row_base_i,
    input  logic [DIM_W-1:0] col_base_i,
    input  logic [DIM_W-1:0] m_size_i,
    input  logic [DIM_W-1:0] n_size_i,

    input  logic                    valid_i [ROW][COL],
    input  logic signed [ACC_W-1:0] acc_i   [ROW][COL],
    input  logic [1:0]              mode_i,

    input  logic signed [BIAS_W-1:0]   bias_i       [COL],
    input  logic signed [MULT_W-1:0]   multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         shift_i      [COL],
    input  logic signed [OUT_W-1:0]    zero_point_i [COL],
    input  logic signed [MULT_W-1:0]   prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         prelu_shift_i      [COL],
    input  logic signed [ACC_W-1:0]    residual_i [ROW][COL],
    input  logic signed [MULT_W-1:0]   residual_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         residual_shift_i [COL],
    input  logic signed [ACC_W-1:0]    residual_zero_point_i [COL],

    output logic                       valid_o [ROW][COL],
    output logic                       valid_tile_o,
    output logic signed [OUT_W-1:0]    data_o  [ROW][COL]
);
    localparam logic signed [OUT_W-1:0] OUT_MAX = {1'b0, {(OUT_W-1){1'b1}}};
    localparam logic signed [OUT_W-1:0] OUT_MIN = {1'b1, {(OUT_W-1){1'b0}}};
    localparam int EXT_DIM_W = DIM_W + 1;
    localparam int WORK_W = BIAS_W;
    localparam int PRODUCT_W = WORK_W + MULT_W;

    logic                       s0_valid [ROW][COL];
    logic                       s1_valid [ROW][COL];
    logic                       s2_valid [ROW][COL];
    logic                       s3_valid [ROW][COL];
    logic                       s4_valid [ROW][COL];
    logic                       s5_valid [ROW][COL];
    logic                       s0_tile_valid;
    logic                       s1_tile_valid;
    logic                       s2_tile_valid;
    logic                       s3_tile_valid;
    logic                       s4_tile_valid;
    logic                       s5_tile_valid;

    logic signed [ACC_W-1:0]    s0_acc      [ROW][COL];
    logic signed [ACC_W-1:0]    s0_residual [ROW][COL];
    logic signed [WORK_W-1:0]   s1_value    [ROW][COL];
    logic signed [WORK_W-1:0]   s2_value    [ROW][COL];
    logic signed [PRODUCT_W-1:0] s2_prelu_product [ROW][COL];
    logic                       s2_prelu_en [ROW][COL];
    logic signed [WORK_W-1:0]   s3_value    [ROW][COL];
    logic signed [PRODUCT_W-1:0] s4_product_lo [ROW][COL];
    logic signed [PRODUCT_W-1:0] s4_product_hi [ROW][COL];
    logic signed [PRODUCT_W-1:0] s5_product [ROW][COL];

    logic [1:0]                 s0_mode;
    logic [1:0]                 s1_mode;
    logic signed [BIAS_W-1:0]   s0_bias       [COL];
    logic signed [MULT_W-1:0]   s0_multiplier [COL];
    logic [SHIFT_W-1:0]         s0_shift      [COL];
    logic signed [OUT_W-1:0]    s0_zero_point [COL];
    logic signed [MULT_W-1:0]   s0_prelu_multiplier [COL];
    logic [SHIFT_W-1:0]         s0_prelu_shift      [COL];
    logic signed [MULT_W-1:0]   s0_residual_multiplier [COL];
    logic [SHIFT_W-1:0]         s0_residual_shift      [COL];
    logic signed [ACC_W-1:0]    s0_residual_zero_point [COL];

    logic signed [MULT_W-1:0]   s1_multiplier [COL];
    logic [SHIFT_W-1:0]         s1_shift      [COL];
    logic signed [OUT_W-1:0]    s1_zero_point [COL];
    logic signed [MULT_W-1:0]   s1_prelu_multiplier [COL];
    logic [SHIFT_W-1:0]         s1_prelu_shift      [COL];

    logic signed [MULT_W-1:0]   s2_multiplier [COL];
    logic [SHIFT_W-1:0]         s2_shift      [COL];
    logic signed [OUT_W-1:0]    s2_zero_point [COL];
    logic [SHIFT_W-1:0]         s2_prelu_shift [COL];

    logic signed [MULT_W-1:0]   s3_multiplier [COL];
    logic [SHIFT_W-1:0]         s3_shift      [COL];
    logic signed [OUT_W-1:0]    s3_zero_point [COL];

    logic [SHIFT_W-1:0]         s4_shift      [COL];
    logic signed [OUT_W-1:0]    s4_zero_point [COL];

    logic [SHIFT_W-1:0]         s5_shift      [COL];
    logic signed [OUT_W-1:0]    s5_zero_point [COL];

    function automatic logic signed [OUT_W-1:0] clamp_int8(input logic signed [PRODUCT_W-1:0] value);
        begin
            if (value > OUT_MAX) begin
                clamp_int8 = OUT_MAX;
            end else if (value < OUT_MIN) begin
                clamp_int8 = OUT_MIN;
            end else begin
                clamp_int8 = value[OUT_W-1:0];
            end
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] round_shift_product(
        input logic signed [PRODUCT_W-1:0] value,
        input logic [SHIFT_W-1:0] shift
    );
        logic signed [PRODUCT_W-1:0] rounded;
        begin
            if (shift == '0) begin
                rounded = value;
            end else begin
                rounded = value + (PRODUCT_W'(1) <<< (shift - 1'b1));
            end
            round_shift_product = rounded >>> shift;
        end
    endfunction

    function automatic logic signed [WORK_W-1:0] extend_acc(input logic signed [ACC_W-1:0] value);
        begin
            extend_acc = {{(WORK_W-ACC_W){value[ACC_W-1]}}, value};
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] multiply_work_mult(
        input logic signed [WORK_W-1:0] value,
        input logic signed [MULT_W-1:0] multiplier
    );
        begin
            // Keep synthesis from inflating this into PRODUCT_W x PRODUCT_W.
            multiply_work_mult = $signed(value) * $signed(multiplier);
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] multiply_work_mult_lo_part(
        input logic signed [WORK_W-1:0] value,
        input logic signed [MULT_W-1:0] multiplier
    );
        localparam int VALUE_PART_W = 32;
        localparam int LO_PRODUCT_W = VALUE_PART_W + 1 + MULT_W;
        logic signed [VALUE_PART_W:0] value_lo_ext;
        logic signed [LO_PRODUCT_W-1:0] product;
        begin
            // value = signed(value[63:32]) * 2^32 + unsigned(value[31:0]).
            // The low slice needs one guard bit so it stays non-negative.
            value_lo_ext = {1'b0, value[VALUE_PART_W-1:0]};
            product = value_lo_ext * multiplier;
            multiply_work_mult_lo_part = {{(PRODUCT_W-LO_PRODUCT_W){product[LO_PRODUCT_W-1]}}, product};
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] multiply_work_mult_hi_part(
        input logic signed [WORK_W-1:0] value,
        input logic signed [MULT_W-1:0] multiplier
    );
        localparam int VALUE_PART_W = 32;
        localparam int HI_PRODUCT_W = VALUE_PART_W + MULT_W;
        logic signed [VALUE_PART_W-1:0] value_hi;
        logic signed [HI_PRODUCT_W-1:0] product;
        logic signed [PRODUCT_W-1:0] product_ext;
        begin
            value_hi = value[WORK_W-1:VALUE_PART_W];
            product = value_hi * multiplier;
            product_ext = {{(PRODUCT_W-HI_PRODUCT_W){product[HI_PRODUCT_W-1]}}, product};
            multiply_work_mult_hi_part = product_ext <<< VALUE_PART_W;
        end
    endfunction

    function automatic logic signed [WORK_W-1:0] finish_prelu(
        input logic signed [WORK_W-1:0] value,
        input logic signed [PRODUCT_W-1:0] product,
        input logic prelu_en,
        input logic [SHIFT_W-1:0] prelu_shift
    );
        logic signed [PRODUCT_W-1:0] shifted;
        begin
            if (prelu_en) begin
                shifted = round_shift_product(product, prelu_shift);
                finish_prelu = shifted[WORK_W-1:0];
            end else begin
                finish_prelu = value;
            end
        end
    endfunction

    function automatic logic signed [WORK_W-1:0] scale_residual_to_work(
        input logic signed [ACC_W-1:0] residual,
        input logic signed [MULT_W-1:0] residual_multiplier,
        input logic [SHIFT_W-1:0] residual_shift,
        input logic signed [ACC_W-1:0] residual_zero_point
    );
        logic signed [WORK_W-1:0] residual_centered;
        logic signed [WORK_W-1:0] residual_scaled;
        logic signed [PRODUCT_W-1:0] product;
        logic signed [PRODUCT_W-1:0] shifted;
        begin
            residual_centered = extend_acc(residual) + extend_acc(residual_zero_point);
            product = multiply_work_mult(residual_centered, residual_multiplier);
            shifted = round_shift_product(product, residual_shift);
            residual_scaled = shifted[WORK_W-1:0];
            scale_residual_to_work = residual_scaled <<< BIAS_SHIFT;
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] finish_requantize(
        input logic signed [PRODUCT_W-1:0] product,
        input logic [SHIFT_W-1:0] shift,
        input logic signed [OUT_W-1:0] zero_point
    );
        logic signed [PRODUCT_W-1:0] shifted;
        logic signed [PRODUCT_W-1:0] with_zero_point;
        begin
            shifted = round_shift_product(product, shift + SHIFT_W'(BIAS_SHIFT));
            with_zero_point = shifted + zero_point;
            finish_requantize = clamp_int8(with_zero_point);
        end
    endfunction

    function automatic logic signed [WORK_W-1:0] add_bias_residual(
        input logic signed [ACC_W-1:0] acc,
        input logic signed [BIAS_W-1:0] bias,
        input logic signed [ACC_W-1:0] residual,
        input logic [1:0] mode,
        input logic signed [MULT_W-1:0] residual_multiplier,
        input logic [SHIFT_W-1:0] residual_shift,
        input logic signed [ACC_W-1:0] residual_zero_point
    );
        logic signed [WORK_W-1:0] working_value;
        begin
            working_value = (extend_acc(acc) <<< BIAS_SHIFT) + bias;

            if (mode == MODE_RESIDUAL) begin
                working_value = working_value +
                                scale_residual_to_work(residual, residual_multiplier,
                                                       residual_shift, residual_zero_point);
            end

            add_bias_residual = working_value;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_tile_valid <= 1'b0;
            s1_tile_valid <= 1'b0;
            s2_tile_valid <= 1'b0;
            s3_tile_valid <= 1'b0;
            s4_tile_valid <= 1'b0;
            s5_tile_valid <= 1'b0;
            valid_tile_o <= 1'b0;
            s0_mode <= MODE_REQUANT;
            s1_mode <= MODE_REQUANT;

            for (int c = 0; c < COL; c++) begin
                s0_bias[c] <= '0;
                s0_multiplier[c] <= '0;
                s0_shift[c] <= '0;
                s0_zero_point[c] <= '0;
                s0_prelu_multiplier[c] <= '0;
                s0_prelu_shift[c] <= '0;
                s0_residual_multiplier[c] <= '0;
                s0_residual_shift[c] <= '0;
                s0_residual_zero_point[c] <= '0;
                s1_multiplier[c] <= '0;
                s1_shift[c] <= '0;
                s1_zero_point[c] <= '0;
                s1_prelu_multiplier[c] <= '0;
                s1_prelu_shift[c] <= '0;
                s2_multiplier[c] <= '0;
                s2_shift[c] <= '0;
                s2_zero_point[c] <= '0;
                s2_prelu_shift[c] <= '0;
                s3_multiplier[c] <= '0;
                s3_shift[c] <= '0;
                s3_zero_point[c] <= '0;
                s4_shift[c] <= '0;
                s4_zero_point[c] <= '0;
                s5_shift[c] <= '0;
                s5_zero_point[c] <= '0;
            end

            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s0_valid[r][c] <= 1'b0;
                    s1_valid[r][c] <= 1'b0;
                    s2_valid[r][c] <= 1'b0;
                    s3_valid[r][c] <= 1'b0;
                    s4_valid[r][c] <= 1'b0;
                    s5_valid[r][c] <= 1'b0;
                    valid_o[r][c] <= 1'b0;
                    s0_acc[r][c] <= '0;
                    s0_residual[r][c] <= '0;
                    s1_value[r][c] <= '0;
                    s2_value[r][c] <= '0;
                    s2_prelu_product[r][c] <= '0;
                    s2_prelu_en[r][c] <= 1'b0;
                    s3_value[r][c] <= '0;
                    s4_product_lo[r][c] <= '0;
                    s4_product_hi[r][c] <= '0;
                    s5_product[r][c] <= '0;
                    data_o[r][c] <= '0;
                end
            end
        end else if (run_en_i) begin
            // Stage 0: capture the tile inputs and clip valid lanes at the layer boundary.
            s0_tile_valid <= valid_tile_i;
            s0_mode <= mode_i;
            for (int c = 0; c < COL; c++) begin
                s0_bias[c] <= bias_i[c];
                s0_multiplier[c] <= multiplier_i[c];
                s0_shift[c] <= shift_i[c];
                s0_zero_point[c] <= zero_point_i[c];
                s0_prelu_multiplier[c] <= prelu_multiplier_i[c];
                s0_prelu_shift[c] <= prelu_shift_i[c];
                s0_residual_multiplier[c] <= residual_multiplier_i[c];
                s0_residual_shift[c] <= residual_shift_i[c];
                s0_residual_zero_point[c] <= residual_zero_point_i[c];
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s0_valid[r][c] <= valid_tile_i && valid_i[r][c] &&
                                      (({1'b0, row_base_i} + EXT_DIM_W'(r)) < {1'b0, m_size_i}) &&
                                      (({1'b0, col_base_i} + EXT_DIM_W'(c)) < {1'b0, n_size_i});
                    s0_acc[r][c] <= acc_i[r][c];
                    s0_residual[r][c] <= residual_i[r][c];
                end
            end

            // Stage 1: accumulator Q0 -> QBIAS_SHIFT, then add folded bias and optional residual.
            s1_tile_valid <= s0_tile_valid;
            s1_mode <= s0_mode;
            for (int c = 0; c < COL; c++) begin
                s1_multiplier[c] <= s0_multiplier[c];
                s1_shift[c] <= s0_shift[c];
                s1_zero_point[c] <= s0_zero_point[c];
                s1_prelu_multiplier[c] <= s0_prelu_multiplier[c];
                s1_prelu_shift[c] <= s0_prelu_shift[c];
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s1_valid[r][c] <= s0_valid[r][c];
                    s1_value[r][c] <= add_bias_residual(s0_acc[r][c], s0_bias[c],
                                                        s0_residual[r][c], s0_mode,
                                                        s0_residual_multiplier[c],
                                                        s0_residual_shift[c],
                                                        s0_residual_zero_point[c]);
                end
            end

            // Stage 2: PReLU multiply only. Positive values bypass in the next stage.
            s2_tile_valid <= s1_tile_valid;
            for (int c = 0; c < COL; c++) begin
                s2_multiplier[c] <= s1_multiplier[c];
                s2_shift[c] <= s1_shift[c];
                s2_zero_point[c] <= s1_zero_point[c];
                s2_prelu_shift[c] <= s1_prelu_shift[c];
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s2_valid[r][c] <= s1_valid[r][c];
                    s2_value[r][c] <= s1_value[r][c];
                    s2_prelu_en[r][c] <= (s1_mode == MODE_PRELU) && s1_value[r][c][WORK_W-1];
                    s2_prelu_product[r][c] <= multiply_work_mult(s1_value[r][c],
                                                                 s1_prelu_multiplier[c]);
                end
            end

            // Stage 3: finish optional PReLU round/shift in the QBIAS_SHIFT domain.
            s3_tile_valid <= s2_tile_valid;
            for (int c = 0; c < COL; c++) begin
                s3_multiplier[c] <= s2_multiplier[c];
                s3_shift[c] <= s2_shift[c];
                s3_zero_point[c] <= s2_zero_point[c];
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s3_valid[r][c] <= s2_valid[r][c];
                    s3_value[r][c] <= finish_prelu(s2_value[r][c],
                                                   s2_prelu_product[r][c],
                                                   s2_prelu_en[r][c],
                                                   s2_prelu_shift[c]);
                end
            end

            // Stage 4: split requant multiply into low/high multiplier partial products.
            s4_tile_valid <= s3_tile_valid;
            for (int c = 0; c < COL; c++) begin
                s4_shift[c] <= s3_shift[c];
                s4_zero_point[c] <= s3_zero_point[c];
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s4_valid[r][c] <= s3_valid[r][c];
                    s4_product_lo[r][c] <= multiply_work_mult_lo_part(s3_value[r][c],
                                                                      s3_multiplier[c]);
                    s4_product_hi[r][c] <= multiply_work_mult_hi_part(s3_value[r][c],
                                                                      s3_multiplier[c]);
                end
            end

            // Stage 5: assemble the full 96-bit requant product from partials.
            s5_tile_valid <= s4_tile_valid;
            for (int c = 0; c < COL; c++) begin
                s5_shift[c] <= s4_shift[c];
                s5_zero_point[c] <= s4_zero_point[c];
            end
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    s5_valid[r][c] <= s4_valid[r][c];
                    s5_product[r][c] <= s4_product_lo[r][c] + s4_product_hi[r][c];
                end
            end

            // Stage 6: round/shift, add output zero-point, clamp, and register output.
            valid_tile_o <= s5_tile_valid;
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    valid_o[r][c] <= s5_valid[r][c];
                    data_o[r][c] <= finish_requantize(s5_product[r][c],
                                                      s5_shift[c],
                                                      s5_zero_point[c]);
                end
            end
        end
    end
endmodule
