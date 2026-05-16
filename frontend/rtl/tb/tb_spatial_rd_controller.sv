`timescale 1ns/1ps

module tb_spatial_rd_controller;
    parameter int ACT_DEPTH = 1;
    parameter int WGT_DEPTH = 2;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = 16;
    localparam int ACT_BYTE_DEPTH = LANES * ACT_DEPTH;
    localparam int ACT_RD_ADDR_W = (ACT_BYTE_DEPTH <= 1) ? 1 : $clog2(ACT_BYTE_DEPTH);
    localparam int WGT_BYTE_DEPTH = LANES * WGT_DEPTH;
    localparam int WGT_RD_ADDR_W = (WGT_BYTE_DEPTH <= 1) ? 1 : $clog2(WGT_BYTE_DEPTH);

    logic clk;
    logic rst_n;
    logic layer_start_i;
    logic [WGT_RD_ADDR_W:0] current_num_filter_i;
    logic stride;
    logic window_loaded_i;
    logic weights_loaded_i;
    logic all_weights_loaded_i;
    logic rd_en_o;
    logic [ACT_RD_ADDR_W-1:0] rd_addr_act_o;
    logic [WGT_RD_ADDR_W-1:0] rd_addr_wgt_o;
    logic read_busy_o;
    logic read_done_o;
    logic filter_round_done_o;
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_rd_controller #(
        .ACT_DEPTH(ACT_DEPTH),
        .WGT_DEPTH(WGT_DEPTH)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .layer_start_i(layer_start_i),
        .current_num_filter_i(current_num_filter_i),
        .stride(stride),
        .window_loaded_i(window_loaded_i),
        .weights_loaded_i(weights_loaded_i),
        .all_weights_loaded_i(all_weights_loaded_i),
        .rd_en_o(rd_en_o),
        .rd_addr_act_o(rd_addr_act_o),
        .rd_addr_wgt_o(rd_addr_wgt_o),
        .read_busy_o(read_busy_o),
        .read_done_o(read_done_o),
        .filter_round_done_o(filter_round_done_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic start_layer();
        begin
            @(negedge clk);
            layer_start_i = 1'b1;
            @(negedge clk);
            layer_start_i = 1'b0;
        end
    endtask

    task automatic expect_read_burst(input int wgt_base, input bit expect_wrap);
        int cycle_cnt;
        begin
            cycle_cnt = 0;
            while (rd_en_o !== 1'b1) begin
                @(posedge clk);
                #1;
            end

            for (int lane = 0; lane < LANES; lane++) begin
                check(rd_en_o === 1'b1, $sformatf("rd_en_o low at lane %0d", lane));
                check(rd_addr_act_o === ACT_RD_ADDR_W'(lane),
                      $sformatf("act addr lane=%0d expected=%0d got=%0d", lane, lane, rd_addr_act_o));
                check(rd_addr_wgt_o === WGT_RD_ADDR_W'(wgt_base + lane),
                      $sformatf("wgt addr lane=%0d expected=%0d got=%0d", lane, wgt_base + lane, rd_addr_wgt_o));
                @(posedge clk);
                #1;
                cycle_cnt++;
            end

            check(rd_en_o === 1'b0, "rd_en_o did not drop after 16 reads");
            check(read_done_o === 1'b1, "read_done_o did not pulse after final read command");
            check(filter_round_done_o === expect_wrap,
                  $sformatf("filter_round_done_o expected=%0d got=%0d", expect_wrap, filter_round_done_o));

            @(posedge clk);
            #1;
            check(read_done_o === 1'b0, "read_done_o did not pulse for one cycle");
            check(filter_round_done_o === 1'b0, "filter_round_done_o did not pulse for one cycle");
            check(cycle_cnt == LANES, "read burst did not contain exactly 16 cycles");
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        layer_start_i = 1'b0;
        current_num_filter_i = (WGT_RD_ADDR_W+1)'(WGT_BYTE_DEPTH);
        stride = 1'b0;
        window_loaded_i = 1'b0;
        weights_loaded_i = 1'b0;
        all_weights_loaded_i = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        start_layer();
        repeat (4) begin
            @(posedge clk);
            #1;
            check(rd_en_o === 1'b0, "controller read before buffers were ready");
        end

        window_loaded_i = 1'b1;
        weights_loaded_i = 1'b1;
        expect_read_burst(0, 1'b0);

        weights_loaded_i = 1'b0;
        repeat (3) begin
            @(posedge clk);
            #1;
            check(rd_en_o === 1'b0, "controller read while next weight tile was not ready");
        end

        weights_loaded_i = 1'b1;
        expect_read_burst(16, 1'b1);

        weights_loaded_i = 1'b0;
        all_weights_loaded_i = 1'b1;
        expect_read_burst(0, 1'b0);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_rd_controller FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_rd_controller PASSED");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
