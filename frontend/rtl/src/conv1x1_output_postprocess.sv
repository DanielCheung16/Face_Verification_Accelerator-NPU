module conv1x1_output_postprocess #(
    parameter int ROW = 14,
    parameter int COL = 16,
    parameter int ACC_W = 32,
    parameter int OUT_W = 8,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,
    parameter int DIM_W = 16
) (
    input  logic [DIM_W-1:0] row_base_i,
    input  logic [DIM_W-1:0] col_base_i,
    input  logic [DIM_W-1:0] m_size_i,
    input  logic [DIM_W-1:0] n_size_i,

    input  logic                    valid_i [ROW][COL],
    input  logic signed [ACC_W-1:0] acc_i   [ROW][COL],
    input  logic [1:0]              mode_i,

    input  logic signed [ACC_W-1:0]    bias_i       [COL],
    input  logic signed [MULT_W-1:0]   multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         shift_i      [COL],
    input  logic signed [OUT_W-1:0]    zero_point_i [COL],
    input  logic signed [MULT_W-1:0]   prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         prelu_shift_i      [COL],
    input  logic signed [ACC_W-1:0]    residual_i [ROW][COL],

    output logic                       valid_o [ROW][COL],
    output logic signed [OUT_W-1:0]    data_o  [ROW][COL]
);
    localparam logic signed [OUT_W-1:0] OUT_MAX = {1'b0, {(OUT_W-1){1'b1}}};
    localparam logic signed [OUT_W-1:0] OUT_MIN = {1'b1, {(OUT_W-1){1'b0}}};
    localparam int EXT_DIM_W = DIM_W + 1;
    localparam int WORK_W = ACC_W + MULT_W + 2;
    localparam int PRODUCT_W = WORK_W + MULT_W;
    localparam logic [1:0] MODE_REQUANT  = 2'd0;
    localparam logic [1:0] MODE_PRELU    = 2'd1;
    localparam logic [1:0] MODE_RESIDUAL = 2'd2;

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

    function automatic logic signed [WORK_W-1:0] extend_biased(input logic signed [ACC_W:0] value);
        begin
            extend_biased = {{(WORK_W-ACC_W-1){value[ACC_W]}}, value};
        end
    endfunction

    function automatic logic signed [WORK_W-1:0] extend_acc(input logic signed [ACC_W-1:0] value);
        begin
            extend_acc = {{(WORK_W-ACC_W){value[ACC_W-1]}}, value};
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] extend_work(input logic signed [WORK_W-1:0] value);
        begin
            extend_work = {{(PRODUCT_W-WORK_W){value[WORK_W-1]}}, value};
        end
    endfunction

    function automatic logic signed [PRODUCT_W-1:0] extend_mult(input logic signed [MULT_W-1:0] value);
        begin
            extend_mult = {{(PRODUCT_W-MULT_W){value[MULT_W-1]}}, value};
        end
    endfunction

    function automatic logic signed [WORK_W-1:0] apply_prelu(
        input logic signed [WORK_W-1:0] value,
        input logic signed [MULT_W-1:0] prelu_multiplier,
        input logic [SHIFT_W-1:0] prelu_shift
    );
        logic signed [PRODUCT_W-1:0] product;
        logic signed [PRODUCT_W-1:0] shifted;
        begin
            if (value[WORK_W-1]) begin
                product = $signed(extend_work(value)) * $signed(extend_mult(prelu_multiplier));
                shifted = round_shift_product(product, prelu_shift);
                apply_prelu = shifted[WORK_W-1:0];
            end else begin
                apply_prelu = value;
            end
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] requantize_from_value(
        input logic signed [WORK_W-1:0] value,
        input logic signed [MULT_W-1:0] multiplier,
        input logic [SHIFT_W-1:0] shift,
        input logic signed [OUT_W-1:0] zero_point
    );
        logic signed [PRODUCT_W-1:0] product;
        logic signed [PRODUCT_W-1:0] shifted;
        logic signed [PRODUCT_W-1:0] with_zero_point;
        begin
            product = $signed(extend_work(value)) * $signed(extend_mult(multiplier));
            shifted = round_shift_product(product, shift);
            with_zero_point = shifted + zero_point;
            requantize_from_value = clamp_int8(with_zero_point);
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] postprocess_value(
        input logic signed [ACC_W-1:0] acc,
        input logic signed [ACC_W-1:0] bias,
        input logic signed [ACC_W-1:0] residual,
        input logic [1:0] mode,
        input logic signed [MULT_W-1:0] multiplier,
        input logic [SHIFT_W-1:0] shift,
        input logic signed [OUT_W-1:0] zero_point,
        input logic signed [MULT_W-1:0] prelu_multiplier,
        input logic [SHIFT_W-1:0] prelu_shift
    );
        logic signed [ACC_W:0] biased;
        logic signed [WORK_W-1:0] working_value;
        begin
            biased = {acc[ACC_W-1], acc} + {bias[ACC_W-1], bias};
            working_value = extend_biased(biased);

            if (mode == MODE_RESIDUAL) begin
                working_value = working_value + extend_acc(residual);
            end else if (mode == MODE_PRELU) begin
                working_value = apply_prelu(working_value, prelu_multiplier, prelu_shift);
            end

            postprocess_value = requantize_from_value(working_value, multiplier, shift, zero_point);
        end
    endfunction

    always_comb begin
        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                valid_o[r][c] = valid_i[r][c] &&
                                (({1'b0, row_base_i} + EXT_DIM_W'(r)) < {1'b0, m_size_i}) &&
                                (({1'b0, col_base_i} + EXT_DIM_W'(c)) < {1'b0, n_size_i});
                data_o[r][c] = postprocess_value(acc_i[r][c], bias_i[c], residual_i[r][c],
                                                 mode_i, multiplier_i[c], shift_i[c],
                                                 zero_point_i[c], prelu_multiplier_i[c],
                                                 prelu_shift_i[c]);
            end
        end
    end
endmodule
