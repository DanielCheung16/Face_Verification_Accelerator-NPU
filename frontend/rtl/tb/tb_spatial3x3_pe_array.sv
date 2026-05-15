`timescale 1ns/1ps

module tb_spatial3x3_pe_array;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int HALF_CYCLE_TIME = 5;

    logic clk;
    logic rst_n;
    logic enable_i;
    logic signed [DATA_W-1:0] activation_i [9];
    logic signed [DATA_W-1:0] weight_i [9];
    logic signed [ACC_W-1:0] psum_o;
    logic valid_o;
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial3x3_pe_array #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable_i(enable_i),
        .activation_i(activation_i),
        .weight_i(weight_i),
        .psum_o(psum_o),
        .valid_o(valid_o)
    );

    function automatic logic signed [ACC_W-1:0] dot3x3(
        input logic signed [DATA_W-1:0] act [9],
        input logic signed [DATA_W-1:0] wgt [9]
    );
        logic signed [ACC_W-1:0] sum;
        begin
            sum = '0;
            for (int i = 0; i < 9; i++) begin
                sum += ACC_W'(act[i]) * ACC_W'(wgt[i]);
            end
            dot3x3 = sum;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic run_case(input int seed);
        logic signed [DATA_W-1:0] act [9];
        logic signed [DATA_W-1:0] wgt [9];
        logic signed [ACC_W-1:0] expected;
        begin
            for (int i = 0; i < 9; i++) begin
                act[i] = DATA_W'($signed((seed * 17 + i * 11) % 127) - 8'sd63);
                wgt[i] = DATA_W'($signed((seed * 23 - i * 7) % 127) - 8'sd31);
            end
            expected = dot3x3(act, wgt);

            @(negedge clk);
            enable_i = 1'b1;
            for (int i = 0; i < 9; i++) begin
                activation_i[i] = act[i];
                weight_i[i] = wgt[i];
            end
            @(negedge clk);
            enable_i = 1'b0;

            repeat (4) @(posedge clk);
            #1;
            check(valid_o === 1'b1,
                  $sformatf("valid_o was not high for seed=%0d", seed));
            check(psum_o === expected,
                  $sformatf("seed=%0d expected=%0d got=%0d", seed, expected, psum_o));

            @(posedge clk);
            #1;
            check(valid_o === 1'b0,
                  $sformatf("valid_o did not drop after seed=%0d", seed));
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        enable_i = 1'b0;
        for (int i = 0; i < 9; i++) begin
            activation_i[i] = '0;
            weight_i[i] = '0;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_case(1);
        run_case(2);
        run_case(7);
        run_case(19);
        run_case(41);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial3x3_pe_array FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial3x3_pe_array PASSED");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
