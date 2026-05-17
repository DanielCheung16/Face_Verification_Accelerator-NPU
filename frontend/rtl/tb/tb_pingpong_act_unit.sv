`timescale 1ns/1ps

module tb_pingpong_act_unit;
    parameter int DEPTH = 3;
    parameter int WORD_W = 128;
    parameter int DATA_W = 8;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = WORD_W / DATA_W;
    localparam int BYTE_DEPTH = LANES * DEPTH;
    localparam int RD_ADDR_W = (BYTE_DEPTH <= 1) ? 1 : $clog2(BYTE_DEPTH);

    logic clk;
    logic rst_n;
    logic clear_i;
    logic swap_i;
    logic wr_en_i;
    logic [WORD_W-1:0] wr_data_i;
    logic wr_full_o;
    logic rd_en_i;
    logic [RD_ADDR_W-1:0] rd_addr_i;
    logic signed [DATA_W-1:0] rd_data_o;
    logic rd_valid_o;
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    pingpong_act_unit #(
        .DEPTH(DEPTH),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear_i),
        .swap_i(swap_i),
        .wr_en_i(wr_en_i),
        .wr_data_i(wr_data_i),
        .wr_full_o(wr_full_o),
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

    task automatic write_word(input logic [WORD_W-1:0] data);
        begin
            @(negedge clk);
            wr_en_i = 1'b1;
            wr_data_i = data;
            @(negedge clk);
            wr_en_i = 1'b0;
        end
    endtask

    task automatic read_byte(input int addr, input logic [DATA_W-1:0] expected);
        begin
            @(negedge clk);
            rd_en_i = 1'b1;
            rd_addr_i = addr[RD_ADDR_W-1:0];
            @(posedge clk);
            #1;
            check(rd_valid_o === 1'b1,
                  $sformatf("rd_valid_o low at addr=%0d", addr));
            check(rd_data_o === expected,
                  $sformatf("addr=%0d expected=0x%02h got=0x%02h",
                            addr, expected, rd_data_o[DATA_W-1:0]));
            @(negedge clk);
            rd_en_i = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        clear_i = 1'b0;
        swap_i = 1'b0;
        wr_en_i = 1'b0;
        wr_data_i = '0;
        rd_en_i = 1'b0;
        rd_addr_i = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        pulse_clear();
        write_word(make_word(8'h00));
        write_word(make_word(8'h10));
        write_word(make_word(8'h20));
        @(posedge clk);
        #1;
        check(wr_full_o === 1'b1, "write buffer 0 did not become full");

        pulse_swap();
        @(posedge clk);
        #1;
        check(wr_full_o === 1'b0, "wr_full_o did not clear after swap");

        // Read current buffer 0.
        read_byte(0, 8'h00);
        read_byte(15, 8'h0f);
        read_byte(16, 8'h10);
        read_byte(47, 8'h2f);

        // Fill buffer 1, then swap and verify that reads come from buffer 1.
        write_word(make_word(8'h80));
        write_word(make_word(8'h90));
        write_word(make_word(8'ha0));
        @(posedge clk);
        #1;
        check(wr_full_o === 1'b1, "write buffer 1 did not become full");

        pulse_swap();
        read_byte(0, 8'h80);
        read_byte(31, 8'h9f);
        read_byte(47, 8'haf);

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
