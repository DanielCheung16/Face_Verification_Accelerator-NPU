`timescale 1ns/1ps

module tb_spatial_act_buffer;
    parameter int DEPTH = 1;
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
    logic swap_i;
    logic wr_en_i;
    logic [3:0] wr_pos_i;
    logic [WORD_W-1:0] wr_data_i;
    logic window_loaded_o;
    logic rd_en_i;
    logic [RD_ADDR_W-1:0] rd_addr_i;
    logic signed [DATA_W-1:0] rd_data_o [NUM_BUF];
    logic rd_valid_o [NUM_BUF];
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_act_buffer #(
        .DEPTH(DEPTH),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear_i),
        .swap_i(swap_i),
        .wr_en_i(wr_en_i),
        .wr_pos_i(wr_pos_i),
        .wr_data_i(wr_data_i),
        .window_loaded_o(window_loaded_o),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(rd_data_o),
        .rd_valid_o(rd_valid_o)
    );

    function automatic logic [WORD_W-1:0] make_word(input int base);
        logic [WORD_W-1:0] word;
        begin
            word = '0;
            for (int lane = 0; lane < LANES; lane++) begin
                word[lane*DATA_W +: DATA_W] = DATA_W'(base + lane);
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

    task automatic pulse_swap();
        begin
            @(negedge clk);
            swap_i = 1'b1;
            @(negedge clk);
            swap_i = 1'b0;
        end
    endtask

    task automatic write_pos(input int pos, input int base);
        begin
            @(negedge clk);
            wr_en_i = 1'b1;
            wr_pos_i = pos[3:0];
            wr_data_i = make_word(base);
            @(negedge clk);
            wr_en_i = 1'b0;
            wr_pos_i = '0;
        end
    endtask

    task automatic read_lane(input int lane, input int base);
        begin
            @(negedge clk);
            rd_en_i = 1'b1;
            rd_addr_i = lane[RD_ADDR_W-1:0];
            @(posedge clk);
            #1;
            for (int pos = 0; pos < NUM_BUF; pos++) begin
                check(rd_valid_o[pos] === 1'b1,
                      $sformatf("rd_valid_o[%0d] low", pos));
                check(rd_data_o[pos] === DATA_W'(base + pos*16 + lane),
                      $sformatf("pos=%0d lane=%0d expected=0x%02h got=0x%02h",
                                pos, lane, DATA_W'(base + pos*16 + lane),
                                rd_data_o[pos][DATA_W-1:0]));
            end
            @(negedge clk);
            rd_en_i = 1'b0;
        end
    endtask

    task automatic load_window(input int base);
        int order [NUM_BUF];
        begin
            order = '{4, 0, 8, 1, 7, 2, 6, 3, 5};
            for (int i = 0; i < NUM_BUF; i++) begin
                write_pos(order[i], base + order[i]*16);
                @(posedge clk);
                #1;
                if (i < NUM_BUF - 1) begin
                    check(window_loaded_o === 1'b0,
                          $sformatf("window_loaded_o rose early at i=%0d", i));
                end
            end
            @(posedge clk);
            #1;
            check(window_loaded_o === 1'b1, "window_loaded_o did not rise after 9 positions");
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        clear_i = 1'b0;
        swap_i = 1'b0;
        wr_en_i = 1'b0;
        wr_pos_i = '0;
        wr_data_i = '0;
        rd_en_i = 1'b0;
        rd_addr_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        pulse_clear();

        load_window(8'h00);
        pulse_swap();
        @(posedge clk);
        #1;
        check(window_loaded_o === 1'b0, "window_loaded_o did not clear after swap");
        read_lane(0, 8'h00);
        read_lane(15, 8'h00);

        load_window(8'h80);
        pulse_swap();
        read_lane(3, 8'h80);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_act_buffer FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_act_buffer PASSED");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
