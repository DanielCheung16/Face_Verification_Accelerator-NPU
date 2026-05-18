`timescale 1ns/1ps

module tb_spatial_ic_accumulator;
    parameter int ACC_W = 32;
    parameter int FILTER_CNT_W = 10;
    parameter int HALF_CYCLE_TIME = 5;

    logic clk;
    logic rst_n;
    logic conv_mode_i;
    logic start_i;
    logic [FILTER_CNT_W-1:0] input_channel_count_i;
    logic valid_i;
    logic signed [ACC_W-1:0] partial_psum_i;
    logic signed [ACC_W-1:0] psum_o;
    logic valid_o;
    int fail_cnt;
    int signed expected_q[$];

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_ic_accumulator #(
        .ACC_W(ACC_W),
        .FILTER_CNT_W(FILTER_CNT_W),
        .LANES(16)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .conv_mode_i(conv_mode_i),
        .start_i(start_i),
        .input_channel_count_i(input_channel_count_i),
        .valid_i(valid_i),
        .partial_psum_i(partial_psum_i),
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
            start_i = 1'b0;
            valid_i = 1'b0;
            partial_psum_i = '0;
        end
    endtask

    task automatic drive_partial(
        input bit conv_mode,
        input logic signed [ACC_W-1:0] value
    );
        begin
            @(negedge clk);
            conv_mode_i = conv_mode;
            valid_i = 1'b1;
            partial_psum_i = value;
        end
    endtask

    task automatic pulse_start(input int unsigned input_channel_count);
        begin
            @(negedge clk);
            start_i = 1'b1;
            input_channel_count_i = FILTER_CNT_W'(input_channel_count);
            valid_i = 1'b0;
            @(negedge clk);
            start_i = 1'b0;
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

    task automatic check_stream_outputs();
        begin
            @(posedge clk);
            #1;
            if (expected_q.size() == 0) begin
                check(valid_o === 1'b0, "unexpected stream valid");
            end else begin
                check(valid_o === 1'b1, "missing stream valid");
                if (valid_o) begin
                    int signed exp;
                    exp = expected_q.pop_front();
                    check(psum_o === ACC_W'(exp),
                          $sformatf("stream psum expected=%0d got=%0d", exp, psum_o));
                end
            end
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        conv_mode_i = 1'b0;
        input_channel_count_i = FILTER_CNT_W'(1);
        drive_idle();

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // DW mode: the PE result is already final, so the module preserves the
        // existing stream timing with a direct bypass.
        drive_partial(1'b0, 32'sd123);
        expect_next(1'b1, 32'sd123, "dw bypass");
        @(negedge clk);
        drive_idle();
        expect_next(1'b0, '0, "dw valid drop");

        // Conv3x3 mode: the PE stream is lane-major inside each IC slice:
        // ic0 lane0..15, ic1 lane0..15, ...  The accumulator therefore keeps
        // one partial sum per lane and emits 16 final lanes on the final IC.
        pulse_start(3);
        for (int ic = 0; ic < 3; ic++) begin
            for (int lane = 0; lane < 16; lane++) begin
                int signed value;
                value = (ic + 1) * 100 + lane;
                if (ic == 2) begin
                    expected_q.push_back((1 * 100 + lane) +
                                         (2 * 100 + lane) +
                                         (3 * 100 + lane));
                end
                drive_partial(1'b1, ACC_W'(value));
                check_stream_outputs();
            end
        end
        @(negedge clk);
        drive_idle();
        expect_next(1'b0, '0, "conv valid drop");

        // A new accumulation must not reuse the previous result.
        pulse_start(2);
        for (int ic = 0; ic < 2; ic++) begin
            for (int lane = 0; lane < 16; lane++) begin
                int signed value;
                value = (ic == 0) ? lane : (10 + lane);
                if (ic == 1) begin
                    expected_q.push_back(lane + 10 + lane);
                end
                drive_partial(1'b1, ACC_W'(value));
                check_stream_outputs();
            end
        end

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
