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
    logic rd_en_i;
    logic [PARAM_ADDR_W-1:0] rd_addr_i;
    logic rd_valid_o;
    logic signed [BIAS_W-1:0] bias_o;
    logic signed [MULT_W-1:0] requant_multiplier_o;
    logic [SHIFT_W-1:0] requant_shift_o;
    logic signed [MULT_W-1:0] prelu_multiplier_o;
    logic [SHIFT_W-1:0] prelu_shift_o;

    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    quant_param_mem #(
        .PARAM_DEPTH(PARAM_DEPTH),
        .PARAM_ADDR_W(PARAM_ADDR_W),
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
        .INIT_PRELU_SHIFT_1(6'd6)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_valid_o(rd_valid_o),
        .bias_o(bias_o),
        .requant_multiplier_o(requant_multiplier_o),
        .requant_shift_o(requant_shift_o),
        .prelu_multiplier_o(prelu_multiplier_o),
        .prelu_shift_o(prelu_shift_o)
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
            rd_addr_i = PARAM_ADDR_W'(addr);
            rd_en_i = 1'b1;
        end
    endtask

    task automatic drop_read_en;
        begin
            @(negedge clk);
            rd_en_i = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        rd_en_i = 1'b0;
        rd_addr_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        request_addr(0);
        @(posedge clk);
        #1;
        check(rd_valid_o === 1'b1, "addr0 valid");
        check(bias_o === 64'sd123, "addr0 bias");
        check(requant_multiplier_o === 32'sd11, "addr0 requant mult");
        check(requant_shift_o === 6'd3, "addr0 requant shift");
        check(prelu_multiplier_o === 32'sd33, "addr0 prelu mult");
        check(prelu_shift_o === 6'd5, "addr0 prelu shift");
        drop_read_en();

        request_addr(1);
        @(posedge clk);
        #1;
        check(rd_valid_o === 1'b1, "addr1 valid");
        check(bias_o === -64'sd77, "addr1 bias");
        check(requant_multiplier_o === -32'sd22, "addr1 requant mult");
        check(requant_shift_o === 6'd4, "addr1 requant shift");
        check(prelu_multiplier_o === -32'sd44, "addr1 prelu mult");
        check(prelu_shift_o === 6'd6, "addr1 prelu shift");
        drop_read_en();

        request_addr(8);
        @(posedge clk);
        #1;
        check(rd_valid_o === 1'b1, "addr8 valid");
        check(bias_o === '0, "addr8 default bias");
        check(requant_multiplier_o === '0, "addr8 default requant mult");
        check(requant_shift_o === '0, "addr8 default requant shift");
        check(prelu_multiplier_o === '0, "addr8 default prelu mult");
        check(prelu_shift_o === '0, "addr8 default prelu shift");
        drop_read_en();

        @(posedge clk);
        #1;
        check(rd_valid_o === 1'b0, "valid drops after rd_en");

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] quant_param_mem FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] quant_param_mem PASSED");
        $finish;
    end
endmodule
