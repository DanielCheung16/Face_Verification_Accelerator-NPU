`timescale 1ns/1ps

module tb_small_output_process;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int DATA_W = 8;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int BIAS_SHIFT = 16;

    localparam logic [2:0] MODE_BYPASS = 3'd0;
    localparam logic [2:0] MODE_REQUANT = 3'd1;
    localparam logic [2:0] MODE_PRELU_REQUANT = 3'd2;
    localparam logic [2:0] MODE_RESIDUAL_REQUANT = 3'd3;

    logic clk;
    logic rst_n;
    logic signed [ACC_W-1:0] psum_i;
    logic valid_i;
    logic [2:0] mode_i;
    logic residual_en_i;
    logic signed [ACC_W-1:0] residual_i;
    logic signed [BIAS_W-1:0] bias_i;
    logic signed [31:0] residual_multiplier_i;
    logic [5:0] residual_shift_i;
    logic signed [BIAS_W-1:0] residual_zero_point_i;
    logic signed [31:0] requant_multiplier_i;
    logic [5:0] requant_shift_i;
    logic signed [ACC_W-1:0] output_zero_point_i;
    logic signed [31:0] prelu_multiplier_i;
    logic [5:0] prelu_shift_i;
    logic signed [DATA_W-1:0] data_o;
    logic valid_o;

    int signed expected_q[$];
    int fail_cnt;
    int out_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    small_output_process #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .DATA_W(DATA_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .psum_i(psum_i),
        .valid_i(valid_i),
        .mode_i(mode_i),
        .residual_en_i(residual_en_i),
        .residual_i(residual_i),
        .bias_i(bias_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .requant_multiplier_i(requant_multiplier_i),
        .requant_shift_i(requant_shift_i),
        .output_zero_point_i(output_zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .data_o(data_o),
        .valid_o(valid_o)
    );

    function automatic longint signed round_shift(input longint signed value, input int shift);
        begin
            if (shift == 0) begin
                round_shift = value;
            end else begin
                round_shift = (value + (64'sd1 <<< (shift - 1))) >>> shift;
            end
        end
    endfunction

    function automatic int signed sat8(input longint signed value);
        begin
            if (value > 127) begin
                sat8 = 127;
            end else if (value < -128) begin
                sat8 = -128;
            end else begin
                sat8 = value;
            end
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic drive_one(
        input logic [2:0] mode,
        input int signed psum,
        input int signed residual,
        input longint signed bias,
        input int signed res_mult,
        input int res_shift,
        input longint signed res_zp,
        input int signed mult,
        input int shift,
        input int signed zp,
        input int signed prelu_mult,
        input int prelu_shift,
        input int signed expected
    );
        begin
            @(negedge clk);
            mode_i = mode;
            psum_i = ACC_W'(psum);
            residual_i = ACC_W'(residual);
            bias_i = BIAS_W'(bias);
            residual_multiplier_i = res_mult;
            residual_shift_i = res_shift[5:0];
            residual_zero_point_i = BIAS_W'(res_zp);
            requant_multiplier_i = mult;
            requant_shift_i = shift[5:0];
            output_zero_point_i = ACC_W'(zp);
            prelu_multiplier_i = prelu_mult;
            prelu_shift_i = prelu_shift[5:0];
            residual_en_i = 1'b0;
            valid_i = 1'b1;
            expected_q.push_back(expected);
            @(negedge clk);
            valid_i = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        out_cnt = 0;
        rst_n = 1'b0;
        psum_i = '0;
        valid_i = 1'b0;
        mode_i = MODE_BYPASS;
        residual_en_i = 1'b0;
        residual_i = '0;
        bias_i = '0;
        residual_multiplier_i = '0;
        residual_shift_i = '0;
        residual_zero_point_i = '0;
        requant_multiplier_i = '0;
        requant_shift_i = '0;
        output_zero_point_i = '0;
        prelu_multiplier_i = '0;
        prelu_shift_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        drive_one(MODE_BYPASS, -200, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, -128);
        drive_one(MODE_REQUANT, 100, 0, 0, 1, 0, 0, 3, 1, -4, 1, 0,
                  sat8(round_shift(((64'sd100 <<< BIAS_SHIFT) * 3), 1 + BIAS_SHIFT) - 4));
        drive_one(MODE_REQUANT, 100, 0, -20, 1, 0, 0, 3, 1, -4, 1, 0,
                  sat8(round_shift((((64'sd100 <<< BIAS_SHIFT) - 20) * 3), 1 + BIAS_SHIFT) - 4));
        drive_one(MODE_PRELU_REQUANT, -100, 0, 0, 1, 0, 0, 2, 1, 1, 1, 1,
                  sat8(round_shift(round_shift(((-64'sd100 <<< BIAS_SHIFT) * 1), 1) * 2,
                                   1 + BIAS_SHIFT) + 1));
        drive_one(MODE_RESIDUAL_REQUANT, 20, 12, 0, 1, 0, 0, 5, 2, -3, 1, 0,
                  sat8(round_shift((((64'sd20 + 12) <<< BIAS_SHIFT) * 5),
                                   2 + BIAS_SHIFT) - 3));
        drive_one(MODE_RESIDUAL_REQUANT, 20, 12, 0, 3, 1, -2, 5, 2, -3, 1, 0,
                  sat8(round_shift(((64'sd20 <<< BIAS_SHIFT) +
                                    (round_shift((64'sd12 - 2) * 3, 1) <<< BIAS_SHIFT)) * 5,
                                   2 + BIAS_SHIFT) - 3));

        wait (out_cnt == 6);
        repeat (2) @(posedge clk);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] small_output_process FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] small_output_process PASSED outputs=%0d", out_cnt);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && valid_o) begin
            int signed exp;
            check(expected_q.size() > 0, "unexpected valid_o");
            if (expected_q.size() > 0) begin
                exp = expected_q.pop_front();
                check(data_o === DATA_W'(exp),
                      $sformatf("output %0d expected=%0d got=%0d", out_cnt, exp, data_o));
            end
            out_cnt++;
        end
    end
endmodule
