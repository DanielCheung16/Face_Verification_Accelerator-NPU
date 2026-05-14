`timescale 1ns/1ps

module tb_conv1x1_output_postprocess;
    parameter int ROW = 4;
    parameter int COL = 5;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int BIAS_SHIFT = 16;
    parameter int OUT_W = 8;
    parameter int MULT_W = 32;
    parameter int SHIFT_W = 6;
    parameter int DIM_W = 16;
    localparam int POST_LATENCY = 6;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic valid_tile_i;

    logic [DIM_W-1:0] row_base_i;
    logic [DIM_W-1:0] col_base_i;
    logic [DIM_W-1:0] m_size_i;
    logic [DIM_W-1:0] n_size_i;

    logic                    valid_i [ROW][COL];
    logic signed [ACC_W-1:0] acc_i   [ROW][COL];
    logic [1:0] mode_i;
    logic signed [BIAS_W-1:0] bias_i       [COL];
    logic signed [MULT_W-1:0] multiplier_i [COL];
    logic [SHIFT_W-1:0] shift_i [COL];
    logic signed [OUT_W-1:0] zero_point_i [COL];
    logic signed [MULT_W-1:0] prelu_multiplier_i [COL];
    logic [SHIFT_W-1:0] prelu_shift_i [COL];
    logic signed [ACC_W-1:0] residual_i [ROW][COL];
    logic signed [MULT_W-1:0] residual_multiplier_i [COL];
    logic [SHIFT_W-1:0] residual_shift_i [COL];
    logic signed [ACC_W-1:0] residual_zero_point_i [COL];

    logic valid_o [ROW][COL];
    logic valid_tile_o;
    logic signed [OUT_W-1:0] data_o [ROW][COL];

    int pass_cnt;
    int fail_cnt;

    conv1x1_output_postprocess #(
        .ROW(ROW),
        .COL(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .BIAS_SHIFT(BIAS_SHIFT),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_tile_i(valid_tile_i),
        .row_base_i(row_base_i),
        .col_base_i(col_base_i),
        .m_size_i(m_size_i),
        .n_size_i(n_size_i),
        .valid_i(valid_i),
        .acc_i(acc_i),
        .mode_i(mode_i),
        .bias_i(bias_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .zero_point_i(zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .residual_i(residual_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .valid_o(valid_o),
        .valid_tile_o(valid_tile_o),
        .data_o(data_o)
    );

    localparam logic [1:0] MODE_REQUANT  = 2'd0;
    localparam logic [1:0] MODE_PRELU    = 2'd1;
    localparam logic [1:0] MODE_RESIDUAL = 2'd2;

    function automatic logic signed [OUT_W-1:0] clamp_ref(input longint signed value);
        begin
            if (value > 127) begin
                clamp_ref = 127;
            end else if (value < -128) begin
                clamp_ref = -128;
            end else begin
                clamp_ref = value[OUT_W-1:0];
            end
        end
    endfunction

    function automatic longint signed round_shift_ref(input longint signed value, input int shift);
        longint signed rounded;
        begin
            if (shift == 0) begin
                rounded = value;
            end else begin
                rounded = value + (64'sd1 <<< (shift - 1));
            end
            round_shift_ref = rounded >>> shift;
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] requant_value_ref(
        input longint signed value,
        input int signed multiplier,
        input int shift,
        input int signed zero_point
    );
        longint signed product;
        longint signed shifted;
        begin
            product = value * longint'(multiplier);
            shifted = round_shift_ref(product, shift);
            requant_value_ref = clamp_ref(shifted + zero_point);
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] postprocess_ref(
        input int signed acc,
        input longint signed bias,
        input int signed residual,
        input logic [1:0] mode,
        input int signed multiplier,
        input int shift,
        input int signed zero_point,
        input int signed prelu_multiplier,
        input int prelu_shift,
        input int signed residual_multiplier,
        input int residual_shift,
        input int signed residual_zero_point
    );
        longint signed value;
        longint signed prelu_product;
        longint signed residual_product;
        begin
            value = (longint'(acc) <<< BIAS_SHIFT) + bias;
            if (mode == MODE_RESIDUAL) begin
                residual_product = (longint'(residual) + longint'(residual_zero_point)) *
                                   longint'(residual_multiplier);
                value = value + (round_shift_ref(residual_product, residual_shift) <<< BIAS_SHIFT);
            end else if ((mode == MODE_PRELU) && (value < 0)) begin
                prelu_product = value * longint'(prelu_multiplier);
                value = round_shift_ref(prelu_product, prelu_shift);
            end
            postprocess_ref = requant_value_ref(value, multiplier, shift + BIAS_SHIFT, zero_point);
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] requant_ref(
        input int signed acc,
        input longint signed bias,
        input int signed multiplier,
        input int shift,
        input int signed zero_point
    );
        begin
            requant_ref = postprocess_ref(acc, bias, 0, MODE_REQUANT, multiplier,
                                          shift, zero_point, 1, 0, 0, 0, 0);
        end
    endfunction
    task automatic check(input bit cond, input string msg);
        begin
            if (!cond) begin
                fail_cnt++;
                $error("%s", msg);
            end else begin
                pass_cnt++;
            end
        end
    endtask

    task automatic run_tile(input string tag);
        begin
            valid_tile_i = 1'b1;
            @(posedge clk);
            valid_tile_i = 1'b0;
            repeat (POST_LATENCY) @(posedge clk);
            #1;
            check(valid_tile_o === 1'b1, $sformatf("%s tile valid missing", tag));
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        valid_tile_i = 1'b0;
        mode_i = MODE_REQUANT;
        row_base_i = 2;
        col_base_i = 3;
        m_size_i = 5;
        n_size_i = 6;

        for (int c = 0; c < COL; c++) begin
            bias_i[c] = ((c - 2) * 17) <<< BIAS_SHIFT;
            multiplier_i[c] = c + 1;
            shift_i[c] = c + 1;
            zero_point_i[c] = c - 2;
            prelu_multiplier_i[c] = c + 1;
            prelu_shift_i[c] = 2;
            residual_multiplier_i[c] = 1;
            residual_shift_i[c] = 0;
            residual_zero_point_i[c] = 0;
        end

        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                valid_i[r][c] = ((r + c) % 2) == 0;
                acc_i[r][c] = (r * 113) - (c * 47) - 100;
                residual_i[r][c] = (r * 19) - (c * 11) + 7;
            end
        end

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        run_tile("requant");
        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                bit exp_valid;
                logic signed [OUT_W-1:0] exp_data;
                exp_valid = valid_i[r][c] && ((row_base_i + r) < m_size_i) && ((col_base_i + c) < n_size_i);
                exp_data = postprocess_ref(acc_i[r][c], bias_i[c], residual_i[r][c],
                                           mode_i, multiplier_i[c], shift_i[c],
                                           zero_point_i[c], prelu_multiplier_i[c],
                                           prelu_shift_i[c], residual_multiplier_i[c],
                                           residual_shift_i[c], residual_zero_point_i[c]);
                check(valid_o[r][c] === exp_valid,
                      $sformatf("valid mismatch r=%0d c=%0d exp=%0d got=%0d", r, c, exp_valid, valid_o[r][c]));
                check(data_o[r][c] === exp_data,
                      $sformatf("data mismatch r=%0d c=%0d exp=%0d got=%0d", r, c, exp_data, data_o[r][c]));
            end
        end

        acc_i[0][0] = 32'sd1000000;
        acc_i[0][1] = -32'sd1000000;
        multiplier_i[0] = 32'sd1024;
        multiplier_i[1] = 32'sd1024;
        shift_i[0] = 0;
        shift_i[1] = 0;
        zero_point_i[0] = 0;
        zero_point_i[1] = 0;
        run_tile("saturation");
        check(data_o[0][0] === 8'sd127, "positive saturation failed");
        check(data_o[0][1] === -8'sd128, "negative saturation failed");

        mode_i = MODE_PRELU;
        acc_i[0][0] = -32'sd64;
        bias_i[0] = '0;
        prelu_multiplier_i[0] = 32'sd1;
        prelu_shift_i[0] = 2;
        multiplier_i[0] = 32'sd1;
        shift_i[0] = 0;
        zero_point_i[0] = 0;
        run_tile("prelu");
        check(data_o[0][0] === -8'sd16,
              $sformatf("prelu mode failed exp=%0d got=%0d", -16, data_o[0][0]));

        mode_i = MODE_RESIDUAL;
        acc_i[0][0] = 32'sd10;
        bias_i[0] = 64'sd1 <<< BIAS_SHIFT;
        residual_i[0][0] = 32'sd20;
        multiplier_i[0] = 32'sd1;
        shift_i[0] = 0;
        zero_point_i[0] = 0;
        run_tile("residual");
        check(data_o[0][0] === 8'sd31, "residual mode failed");

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] conv1x1_output_postprocess FAILED pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("[TB] conv1x1_output_postprocess PASSED pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $finish;
    end
endmodule
