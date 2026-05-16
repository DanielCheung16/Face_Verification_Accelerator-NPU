`timescale 1ns/1ps

module tb_spatial_wgt_buffer;
    parameter int DEPTH = 2;
    parameter int WORD_W = 128;
    parameter int DATA_W = 8;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int NUM_BUF = 9;
    localparam int LANES = WORD_W / DATA_W;
    localparam int BYTE_DEPTH = LANES * DEPTH;
    localparam int RD_ADDR_W = (BYTE_DEPTH <= 1) ? 1 : $clog2(BYTE_DEPTH);

    logic clk;
    logic rst_n;
    logic clear_i;
    logic wr_en_i;
    logic [3:0] wr_pos_i;
    logic [WORD_W-1:0] wr_data_i;
    logic weights_loaded_o;
    logic all_weights_loaded_o;
    logic rd_en_i;
    logic [RD_ADDR_W-1:0] rd_addr_i;
    logic signed [DATA_W-1:0] rd_data_o [NUM_BUF];
    logic rd_valid_o [NUM_BUF];
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_wgt_buffer #(
        .DEPTH(DEPTH),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear_i),
        .wr_en_i(wr_en_i),
        .wr_pos_i(wr_pos_i),
        .wr_data_i(wr_data_i),
        .weights_loaded_o(weights_loaded_o),
        .all_weights_loaded_o(all_weights_loaded_o),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(rd_data_o),
        .rd_valid_o(rd_valid_o)
    );

    function automatic logic [WORD_W-1:0] make_word(input int pos, input int word_idx);
        logic [WORD_W-1:0] word;
        begin
            word = '0;
            for (int lane = 0; lane < LANES; lane++) begin
                word[lane*DATA_W +: DATA_W] = DATA_W'(pos * 32 + word_idx * 16 + lane);
            end
            make_word = word;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic pulse_clear();
        begin
            @(negedge clk);
            clear_i = 1'b1;
            @(negedge clk);
            clear_i = 1'b0;
        end
    endtask

    task automatic write_pos_word(input int pos, input int word_idx);
        begin
            @(negedge clk);
            wr_en_i = 1'b1;
            wr_pos_i = pos[3:0];
            wr_data_i = make_word(pos, word_idx);
            @(negedge clk);
            wr_en_i = 1'b0;
            wr_pos_i = '0;
        end
    endtask

    task automatic read_channel(input int byte_addr);
        int word_idx;
        int lane;
        begin
            word_idx = byte_addr / LANES;
            lane = byte_addr % LANES;
            @(negedge clk);
            rd_en_i = 1'b1;
            rd_addr_i = byte_addr[RD_ADDR_W-1:0];
            @(posedge clk);
            #1;
            for (int pos = 0; pos < NUM_BUF; pos++) begin
                check(rd_valid_o[pos] === 1'b1,
                      $sformatf("rd_valid_o[%0d] low", pos));
                check(rd_data_o[pos] === DATA_W'(pos * 32 + word_idx * 16 + lane),
                      $sformatf("pos=%0d byte_addr=%0d expected=0x%02h got=0x%02h",
                                pos, byte_addr,
                                DATA_W'(pos * 32 + word_idx * 16 + lane),
                                rd_data_o[pos][DATA_W-1:0]));
            end
            @(negedge clk);
            rd_en_i = 1'b0;
        end
    endtask

    task automatic read_old_write_next(input int byte_addr, input int wr_pos, input int wr_word_idx);
        int word_idx;
        int lane;
        begin
            word_idx = byte_addr / LANES;
            lane = byte_addr % LANES;
            @(negedge clk);
            rd_en_i = 1'b1;
            rd_addr_i = byte_addr[RD_ADDR_W-1:0];
            wr_en_i = 1'b1;
            wr_pos_i = wr_pos[3:0];
            wr_data_i = make_word(wr_pos, wr_word_idx);
            @(posedge clk);
            #1;
            for (int pos = 0; pos < NUM_BUF; pos++) begin
                check(rd_valid_o[pos] === 1'b1,
                      $sformatf("overlap rd_valid_o[%0d] low", pos));
                check(rd_data_o[pos] === DATA_W'(pos * 32 + word_idx * 16 + lane),
                      $sformatf("overlap pos=%0d byte_addr=%0d expected old=0x%02h got=0x%02h",
                                pos, byte_addr,
                                DATA_W'(pos * 32 + word_idx * 16 + lane),
                                rd_data_o[pos][DATA_W-1:0]));
            end
            @(negedge clk);
            rd_en_i = 1'b0;
            wr_en_i = 1'b0;
            wr_pos_i = '0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        clear_i = 1'b0;
        wr_en_i = 1'b0;
        wr_pos_i = '0;
        wr_data_i = '0;
        rd_en_i = 1'b0;
        rd_addr_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        pulse_clear();

        for (int pos = 0; pos < NUM_BUF; pos++) begin
            write_pos_word(pos, 0);
            #1;
            if (pos != (NUM_BUF - 1)) begin
                check(weights_loaded_o === 1'b0,
                      $sformatf("weights_loaded_o rose before word group 0 got all 9 positions, pos=%0d", pos));
            end
        end
        check(weights_loaded_o === 1'b1,
              "weights_loaded_o did not rise after word group 0 got all 9 positions");
        check(all_weights_loaded_o === 1'b0,
              "all_weights_loaded_o rose before all DEPTH word groups were loaded");

        read_channel(0);
        read_channel(15);

        for (int pos = 0; pos < NUM_BUF; pos++) begin
            read_old_write_next(pos, pos, 1);
            #1;
            if (pos != (NUM_BUF - 1)) begin
                check(weights_loaded_o === 1'b0,
                      $sformatf("weights_loaded_o stayed high while word group 1 was still incomplete, pos=%0d", pos));
            end
        end
        #1;
        check(weights_loaded_o === 1'b1,
              "weights_loaded_o did not rise after word group 1 got all 9 positions");
        check(all_weights_loaded_o === 1'b1,
              "all_weights_loaded_o did not rise after all DEPTH word groups were loaded");

        read_channel(20);
        read_channel(31);

        pulse_clear();
        @(posedge clk);
        #1;
        check(weights_loaded_o === 1'b0, "weights_loaded_o did not clear");
        check(all_weights_loaded_o === 1'b0, "all_weights_loaded_o did not clear");

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_wgt_buffer FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_wgt_buffer PASSED");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
