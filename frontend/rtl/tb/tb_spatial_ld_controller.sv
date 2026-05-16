`timescale 1ns/1ps

module tb_spatial_ld_controller;
    parameter int ADDR_W = 16;
    parameter int WORD_W = 128;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int NUM_POS = 9;
    localparam int POS_W = 4;

    logic clk;
    logic rst_n;
    logic load_start_i;
    logic [ADDR_W-1:0] act_base_addr_i;
    logic [ADDR_W-1:0] wgt_base_addr_i;
    logic [1:0] num_filter_code_i;
    logic [2:0] ifmap_size_code_i;
    logic [ADDR_W-1:0] tile_offset_i;
    logic [ADDR_W-1:0] out_x_i;
    logic [ADDR_W-1:0] out_y_i;
    logic stride_i;
    logic pad_i;
    logic all_weights_loaded_i;
    logic gb_act_rd_en_o;
    logic [ADDR_W-1:0] gb_act_rd_addr_o;
    logic [WORD_W-1:0] gb_act_rd_data_i;
    logic gb_wgt_rd_en_o;
    logic [ADDR_W-1:0] gb_wgt_rd_addr_o;
    logic [WORD_W-1:0] gb_wgt_rd_data_i;
    logic act_wr_en_o;
    logic [POS_W-1:0] act_wr_pos_o;
    logic [WORD_W-1:0] act_wr_data_o;
    logic wgt_wr_en_o;
    logic [POS_W-1:0] wgt_wr_pos_o;
    logic [WORD_W-1:0] wgt_wr_data_o;
    logic load_busy_o;
    logic load_done_o;

    int fail_cnt;
    int act_wr_cnt;
    int wgt_wr_cnt;
    bit saw_act_zero [NUM_POS];

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_ld_controller #(
        .ADDR_W(ADDR_W),
        .WORD_W(WORD_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .load_start_i(load_start_i),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .tile_offset_i(tile_offset_i),
        .out_x_i(out_x_i),
        .out_y_i(out_y_i),
        .stride_i(stride_i),
        .pad_i(pad_i),
        .all_weights_loaded_i(all_weights_loaded_i),
        .gb_act_rd_en_o(gb_act_rd_en_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_en_o(gb_wgt_rd_en_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .act_wr_en_o(act_wr_en_o),
        .act_wr_pos_o(act_wr_pos_o),
        .act_wr_data_o(act_wr_data_o),
        .wgt_wr_en_o(wgt_wr_en_o),
        .wgt_wr_pos_o(wgt_wr_pos_o),
        .wgt_wr_data_o(wgt_wr_data_o),
        .load_busy_o(load_busy_o),
        .load_done_o(load_done_o)
    );

    function automatic logic [WORD_W-1:0] make_word(input int tag, input int addr);
        logic [WORD_W-1:0] word;
        begin
            word = '0;
            word[31:0] = 32'(addr);
            word[63:32] = 32'(tag);
            make_word = word;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic pulse_start();
        begin
            @(negedge clk);
            load_start_i = 1'b1;
            @(negedge clk);
            load_start_i = 1'b0;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gb_act_rd_data_i <= '0;
            gb_wgt_rd_data_i <= '0;
        end else begin
            gb_act_rd_data_i <= make_word(32'hA0, gb_act_rd_addr_o);
            gb_wgt_rd_data_i <= make_word(32'hB0, gb_wgt_rd_addr_o);
        end
    end

    initial begin
        fail_cnt = 0;
        act_wr_cnt = 0;
        wgt_wr_cnt = 0;
        for (int pos = 0; pos < NUM_POS; pos++) begin
            saw_act_zero[pos] = 1'b0;
        end

        rst_n = 1'b0;
        load_start_i = 1'b0;
        act_base_addr_i = 16'd100;
        wgt_base_addr_i = 16'd1000;
        num_filter_code_i = 2'd0;
        ifmap_size_code_i = 3'd0;
        tile_offset_i = 16'd0;
        out_x_i = 16'd0;
        out_y_i = 16'd0;
        stride_i = 1'b0;
        pad_i = 1'b1;
        all_weights_loaded_i = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        pulse_start();
        while (load_done_o !== 1'b1) begin
            @(posedge clk);
            #1;
            if (act_wr_en_o) begin
                act_wr_cnt++;
                if (act_wr_data_o == '0) begin
                    saw_act_zero[act_wr_pos_o] = 1'b1;
                end
            end
            if (wgt_wr_en_o) begin
                wgt_wr_cnt++;
                check(wgt_wr_data_o[63:32] == 32'hB0, "weight write data tag mismatch");
            end
        end

        check(act_wr_cnt == 9, $sformatf("expected 9 activation writes, got %0d", act_wr_cnt));
        check(wgt_wr_cnt == 9, $sformatf("expected 9 weight writes, got %0d", wgt_wr_cnt));
        check(saw_act_zero[0] && saw_act_zero[1] && saw_act_zero[2] &&
              saw_act_zero[3] && saw_act_zero[6],
              "top-left same-padding did not zero the expected window positions");
        check(!saw_act_zero[4] && !saw_act_zero[5] && !saw_act_zero[7] && !saw_act_zero[8],
              "top-left same-padding zeroed a valid window position");

        @(posedge clk);
        #1;
        act_wr_cnt = 0;
        wgt_wr_cnt = 0;
        for (int pos = 0; pos < NUM_POS; pos++) begin
            saw_act_zero[pos] = 1'b0;
        end
        out_x_i = 16'd1;
        out_y_i = 16'd1;
        ifmap_size_code_i = 3'd0;
        stride_i = 1'b1;
        pad_i = 1'b0;
        tile_offset_i = 16'd16;
        all_weights_loaded_i = 1'b1;

        pulse_start();
        while (load_done_o !== 1'b1) begin
            @(posedge clk);
            #1;
            if (act_wr_en_o) begin
                act_wr_cnt++;
                check(act_wr_data_o[63:32] == 32'hA0, "activation write data tag mismatch");
            end
            if (wgt_wr_en_o) begin
                wgt_wr_cnt++;
            end
        end

        check(act_wr_cnt == 9, $sformatf("expected 9 activation writes after weights loaded, got %0d", act_wr_cnt));
        check(wgt_wr_cnt == 0, $sformatf("expected 0 weight writes after all_weights_loaded_i, got %0d", wgt_wr_cnt));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_ld_controller FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_ld_controller PASSED");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
