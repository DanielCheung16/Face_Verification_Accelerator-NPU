`timescale 1ns/1ps

module tb_quant_param_mem;
    parameter int PARAM_DEPTH = 16;
    parameter int PARAM_ADDR_W = 4;
    parameter int BIAS_W = 64;
    parameter int MULT_W = 32;
    parameter int SHIFT_W = 6;
    parameter int HALF_CYCLE_TIME = 5;

    logic clk;
    logic rst_n;
    logic common_rd_en_i;
    logic [PARAM_ADDR_W-1:0] common_rd_addr_i;
    logic prelu_rd_en_i;
    logic [PARAM_ADDR_W-1:0] prelu_rd_addr_i;
    logic residual_rd_en_i;
    logic [PARAM_ADDR_W-1:0] residual_rd_addr_i;
    logic common_rd_valid_o;
    logic prelu_rd_valid_o;
    logic residual_rd_valid_o;
    logic signed [BIAS_W-1:0] bias_o;
    logic signed [MULT_W-1:0] requant_multiplier_o;
    logic [SHIFT_W-1:0] requant_shift_o;
    logic signed [MULT_W-1:0] prelu_multiplier_o;
    logic [SHIFT_W-1:0] prelu_shift_o;
    logic signed [MULT_W-1:0] residual_multiplier_o;
    logic [SHIFT_W-1:0] residual_shift_o;
    logic signed [BIAS_W-1:0] residual_zero_point_o;

    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    quant_param_mem #(
        .COMMON_PARAM_DEPTH(PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(PARAM_DEPTH),
        .COMMON_PARAM_ADDR_W(PARAM_ADDR_W),
        .PRELU_PARAM_ADDR_W(PARAM_ADDR_W),
        .RESIDUAL_PARAM_ADDR_W(PARAM_ADDR_W),
        .BIAS_W(BIAS_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .INIT_BIAS_0(64'sd123),
        .INIT_BIAS_1(-64'sd77),
        .INIT_REQUANT_MULT_0(32'sd11),
        .INIT_REQUANT_MULT_1(-32'sd22),
        .INIT_REQUANT_SHIFT_0(6'd3),
        .INIT_REQUANT_SHIFT_1(6'd4),
        .INIT_PRELU_MULT_0(32'sd33),
        .INIT_PRELU_MULT_1(-32'sd44),
        .INIT_PRELU_SHIFT_0(6'd5),
        .INIT_PRELU_SHIFT_1(6'd6),
        .INIT_RESIDUAL_MULT_0(32'sd55),
        .INIT_RESIDUAL_MULT_1(-32'sd66),
        .INIT_RESIDUAL_SHIFT_0(6'd7),
        .INIT_RESIDUAL_SHIFT_1(6'd8),
        .INIT_RESIDUAL_ZERO_POINT_0(-64'sd9),
        .INIT_RESIDUAL_ZERO_POINT_1(64'sd10)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .common_rd_en_i(common_rd_en_i),
        .common_rd_addr_i(common_rd_addr_i),
        .prelu_rd_en_i(prelu_rd_en_i),
        .prelu_rd_addr_i(prelu_rd_addr_i),
        .residual_rd_en_i(residual_rd_en_i),
        .residual_rd_addr_i(residual_rd_addr_i),
        .common_rd_valid_o(common_rd_valid_o),
        .prelu_rd_valid_o(prelu_rd_valid_o),
        .residual_rd_valid_o(residual_rd_valid_o),
        .bias_o(bias_o),
        .requant_multiplier_o(requant_multiplier_o),
        .requant_shift_o(requant_shift_o),
        .prelu_multiplier_o(prelu_multiplier_o),
        .prelu_shift_o(prelu_shift_o),
        .residual_multiplier_o(residual_multiplier_o),
        .residual_shift_o(residual_shift_o),
        .residual_zero_point_o(residual_zero_point_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic request_addr(input int addr);
        begin
            @(negedge clk);
            common_rd_addr_i = PARAM_ADDR_W'(addr);
            prelu_rd_addr_i = PARAM_ADDR_W'(addr);
            residual_rd_addr_i = PARAM_ADDR_W'(addr);
            common_rd_en_i = 1'b1;
            prelu_rd_en_i = 1'b1;
            residual_rd_en_i = 1'b1;
        end
    endtask

    task automatic drop_read_en;
        begin
            @(negedge clk);
            common_rd_en_i = 1'b0;
            prelu_rd_en_i = 1'b0;
            residual_rd_en_i = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        common_rd_en_i = 1'b0;
        prelu_rd_en_i = 1'b0;
        residual_rd_en_i = 1'b0;
        common_rd_addr_i = '0;
        prelu_rd_addr_i = '0;
        residual_rd_addr_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        request_addr(0);
        @(posedge clk);
        #1;
        check(common_rd_valid_o === 1'b1, "addr0 common valid");
        check(prelu_rd_valid_o === 1'b1, "addr0 prelu valid");
        check(residual_rd_valid_o === 1'b1, "addr0 residual valid");
        check(bias_o === 64'sd123, "addr0 bias");
        check(requant_multiplier_o === 32'sd11, "addr0 requant mult");
        check(requant_shift_o === 6'd3, "addr0 requant shift");
        check(prelu_multiplier_o === 32'sd33, "addr0 prelu mult");
        check(prelu_shift_o === 6'd5, "addr0 prelu shift");
        check(residual_multiplier_o === 32'sd55, "addr0 residual mult");
        check(residual_shift_o === 6'd7, "addr0 residual shift");
        check(residual_zero_point_o === -64'sd9, "addr0 residual zero-point");
        drop_read_en();

        request_addr(1);
        @(posedge clk);
        #1;
        check(common_rd_valid_o === 1'b1, "addr1 common valid");
        check(prelu_rd_valid_o === 1'b1, "addr1 prelu valid");
        check(residual_rd_valid_o === 1'b1, "addr1 residual valid");
        check(bias_o === -64'sd77, "addr1 bias");
        check(requant_multiplier_o === -32'sd22, "addr1 requant mult");
        check(requant_shift_o === 6'd4, "addr1 requant shift");
        check(prelu_multiplier_o === -32'sd44, "addr1 prelu mult");
        check(prelu_shift_o === 6'd6, "addr1 prelu shift");
        check(residual_multiplier_o === -32'sd66, "addr1 residual mult");
        check(residual_shift_o === 6'd8, "addr1 residual shift");
        check(residual_zero_point_o === 64'sd10, "addr1 residual zero-point");
        drop_read_en();

        request_addr(8);
        @(posedge clk);
        #1;
        check(common_rd_valid_o === 1'b1, "addr8 common valid");
        check(prelu_rd_valid_o === 1'b1, "addr8 prelu valid");
        check(residual_rd_valid_o === 1'b1, "addr8 residual valid");
        check(bias_o === '0, "addr8 default bias");
        check(requant_multiplier_o === '0, "addr8 default requant mult");
        check(requant_shift_o === '0, "addr8 default requant shift");
        check(prelu_multiplier_o === '0, "addr8 default prelu mult");
        check(prelu_shift_o === '0, "addr8 default prelu shift");
        check(residual_multiplier_o === '0, "addr8 default residual mult");
        check(residual_shift_o === '0, "addr8 default residual shift");
        check(residual_zero_point_o === '0, "addr8 default residual zero-point");
        drop_read_en();

        @(posedge clk);
        #1;
        check(common_rd_valid_o === 1'b0, "common valid drops after rd_en");
        check(prelu_rd_valid_o === 1'b0, "prelu valid drops after rd_en");
        check(residual_rd_valid_o === 1'b0, "residual valid drops after rd_en");

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] quant_param_mem FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] quant_param_mem PASSED");
        $finish;
    end
endmodule
