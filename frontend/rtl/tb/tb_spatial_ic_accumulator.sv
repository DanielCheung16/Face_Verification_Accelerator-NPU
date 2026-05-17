`timescale 1ns/1ps

module tb_spatial_ic_accumulator;
    parameter int ACC_W = 32;
    parameter int HALF_CYCLE_TIME = 5;

    logic clk;
    logic rst_n;
    logic conv_mode_i;
    logic valid_i;
    logic signed [ACC_W-1:0] partial_psum_i;
    logic ic_first_i;
    logic ic_last_i;
    logic signed [ACC_W-1:0] psum_o;
    logic valid_o;
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_ic_accumulator #(
        .ACC_W(ACC_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .conv_mode_i(conv_mode_i),
        .valid_i(valid_i),
        .partial_psum_i(partial_psum_i),
        .ic_first_i(ic_first_i),
        .ic_last_i(ic_last_i),
        .psum_o(psum_o),
        .valid_o(valid_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic drive_idle();
        begin
            valid_i = 1'b0;
            partial_psum_i = '0;
            ic_first_i = 1'b0;
            ic_last_i = 1'b0;
        end
    endtask

    task automatic drive_partial(
        input bit conv_mode,
        input logic signed [ACC_W-1:0] value,
        input bit ic_first,
        input bit ic_last
    );
        begin
            @(negedge clk);
            conv_mode_i = conv_mode;
            valid_i = 1'b1;
            partial_psum_i = value;
            ic_first_i = ic_first;
            ic_last_i = ic_last;
        end
    endtask

    task automatic expect_next(
        input bit expect_valid,
        input logic signed [ACC_W-1:0] expect_psum,
        input string tag
    );
        begin
            @(posedge clk);
            #1;
            check(valid_o === expect_valid,
                  $sformatf("%s valid expected=%0b got=%0b", tag, expect_valid, valid_o));
            if (expect_valid) begin
                check(psum_o === expect_psum,
                      $sformatf("%s psum expected=%0d got=%0d", tag, expect_psum, psum_o));
            end
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        conv_mode_i = 1'b0;
        drive_idle();

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // DW mode: the PE result is already final, so the module is a
        // one-cycle registered bypass.
        drive_partial(1'b0, 32'sd123, 1'b0, 1'b0);
        expect_next(1'b1, 32'sd123, "dw bypass");
        @(negedge clk);
        drive_idle();
        expect_next(1'b0, '0, "dw valid drop");

        // Conv3x3 mode: accumulate three IC partial sums and only emit on
        // ic_last_i. This matches the first-layer IC=3 case but is not fixed
        // to three cycles.
        drive_partial(1'b1, 32'sd10, 1'b1, 1'b0);
        expect_next(1'b0, '0, "conv ic0");
        drive_partial(1'b1, -32'sd7, 1'b0, 1'b0);
        expect_next(1'b0, '0, "conv ic1");
        drive_partial(1'b1, 32'sd25, 1'b0, 1'b1);
        expect_next(1'b1, 32'sd28, "conv ic2 last");
        @(negedge clk);
        drive_idle();
        expect_next(1'b0, '0, "conv valid drop");

        // Single-IC conv is legal for the accumulator: first and last are the
        // same beat, so the registered output equals the partial sum.
        drive_partial(1'b1, -32'sd300, 1'b1, 1'b1);
        expect_next(1'b1, -32'sd300, "conv single ic");

        // A new accumulation must not reuse the previous result.
        drive_partial(1'b1, 32'sd5, 1'b1, 1'b0);
        expect_next(1'b0, '0, "conv restart ic0");
        drive_partial(1'b1, 32'sd6, 1'b0, 1'b1);
        expect_next(1'b1, 32'sd11, "conv restart last");

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_ic_accumulator FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_ic_accumulator PASSED");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
