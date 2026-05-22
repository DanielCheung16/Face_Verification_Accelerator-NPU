`timescale 1ns/1ps

module tb_conv1x1_output_postprocess;
    parameter int LANES = 5;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int BIAS_SHIFT = 16;
    parameter int OUT_W = 8;
    parameter int MULT_W = 32;
    parameter int SHIFT_W = 6;
    localparam int POST_LATENCY = 8;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic valid_i;
    logic lane_valid_i [LANES];
    logic signed [ACC_W-1:0] acc_i [LANES];
    logic [1:0] mode_i;
    logic signed [BIAS_W-1:0] bias_i [LANES];
    logic signed [MULT_W-1:0] multiplier_i [LANES];
    logic [SHIFT_W-1:0] shift_i [LANES];
    logic signed [OUT_W-1:0] zero_point_i [LANES];
    logic signed [MULT_W-1:0] prelu_multiplier_i [LANES];
    logic [SHIFT_W-1:0] prelu_shift_i [LANES];
    logic signed [ACC_W-1:0] residual_i [LANES];
    logic signed [MULT_W-1:0] residual_multiplier_i [LANES];
    logic [SHIFT_W-1:0] residual_shift_i [LANES];
    logic signed [ACC_W-1:0] residual_zero_point_i [LANES];

    logic valid_o;
    logic lane_valid_o [LANES];
    logic signed [OUT_W-1:0] data_o [LANES];

    int pass_cnt;
    int fail_cnt;

    conv1x1_output_postprocess #(
        .LANES(LANES),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .BIAS_SHIFT(BIAS_SHIFT),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_i(valid_i),
        .lane_valid_i(lane_valid_i),
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
        .lane_valid_o(lane_valid_o),
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
        longint signed product;
        begin
            value = (longint'(acc) <<< BIAS_SHIFT) + bias;
            if (mode == MODE_RESIDUAL) begin
                product = (longint'(residual) + longint'(residual_zero_point)) *
                          longint'(residual_multiplier);
                value = value + (round_shift_ref(product, residual_shift) <<< BIAS_SHIFT);
            end else if ((mode == MODE_PRELU) && (value < 0)) begin
                product = value * longint'(prelu_multiplier);
                value = round_shift_ref(product, prelu_shift);
            end
            product = value * longint'(multiplier);
            value = round_shift_ref(product, shift + BIAS_SHIFT) + zero_point;
            postprocess_ref = clamp_ref(value);
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

    task automatic run_row(input string tag);
        logic signed [OUT_W-1:0] exp_data [LANES];
        logic exp_valid [LANES];
        begin
            for (int i = 0; i < LANES; i++) begin
                exp_valid[i] = lane_valid_i[i];
                exp_data[i] = postprocess_ref(acc_i[i], bias_i[i], residual_i[i],
                                              mode_i, multiplier_i[i], shift_i[i],
                                              zero_point_i[i], prelu_multiplier_i[i],
                                              prelu_shift_i[i], residual_multiplier_i[i],
                                              residual_shift_i[i], residual_zero_point_i[i]);
            end

            valid_i = 1'b1;
            @(posedge clk);
            valid_i = 1'b0;
            repeat (POST_LATENCY) @(posedge clk);
            #1;
            check(valid_o === 1'b1, $sformatf("%s valid missing", tag));
            for (int i = 0; i < LANES; i++) begin
                check(lane_valid_o[i] === exp_valid[i],
                      $sformatf("%s lane valid mismatch i=%0d exp=%0d got=%0d",
                                tag, i, exp_valid[i], lane_valid_o[i]));
                check(data_o[i] === exp_data[i],
                      $sformatf("%s data mismatch i=%0d exp=%0d got=%0d",
                                tag, i, exp_data[i], data_o[i]));
            end
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
        valid_i = 1'b0;
        mode_i = MODE_REQUANT;

        for (int i = 0; i < LANES; i++) begin
            lane_valid_i[i] = (i != 3);
            acc_i[i] = (i * 113) - 180;
            bias_i[i] = ((i - 2) * 17) <<< BIAS_SHIFT;
            multiplier_i[i] = i + 1;
            shift_i[i] = i + 1;
            zero_point_i[i] = i - 2;
            prelu_multiplier_i[i] = i + 1;
            prelu_shift_i[i] = 2;
            residual_i[i] = (i * 19) - 33;
            residual_multiplier_i[i] = 1;
            residual_shift_i[i] = 0;
            residual_zero_point_i[i] = 0;
        end

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        run_row("requant");

        acc_i[0] = 32'sd1000000;
        acc_i[1] = -32'sd1000000;
        multiplier_i[0] = 32'sd1024;
        multiplier_i[1] = 32'sd1024;
        shift_i[0] = 0;
        shift_i[1] = 0;
        zero_point_i[0] = 0;
        zero_point_i[1] = 0;
        run_row("saturation");
        check(data_o[0] === 8'sd127, "positive saturation failed");
        check(data_o[1] === -8'sd128, "negative saturation failed");

        mode_i = MODE_PRELU;
        acc_i[0] = -32'sd64;
        bias_i[0] = '0;
        prelu_multiplier_i[0] = 32'sd1;
        prelu_shift_i[0] = 2;
        multiplier_i[0] = 32'sd1;
        shift_i[0] = 0;
        zero_point_i[0] = 0;
        run_row("prelu");
        check(data_o[0] === -8'sd16,
              $sformatf("prelu mode failed exp=%0d got=%0d", -16, data_o[0]));

        mode_i = MODE_RESIDUAL;
        acc_i[0] = 32'sd10;
        bias_i[0] = 64'sd1 <<< BIAS_SHIFT;
        residual_i[0] = 32'sd20;
        multiplier_i[0] = 32'sd1;
        shift_i[0] = 0;
        zero_point_i[0] = 0;
        run_row("residual");
        check(data_o[0] === 8'sd31, "residual mode failed");

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] conv1x1_output_postprocess FAILED pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("[TB] conv1x1_output_postprocess PASSED pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $finish;
    end
endmodule
