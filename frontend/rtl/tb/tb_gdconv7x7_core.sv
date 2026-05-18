`timescale 1ns/1ps

module tb_gdconv7x7_core;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int GB_DATA_W = 128;
    parameter int GB_ADDR_W = 12;
    parameter int CHANNELS = 512;
    parameter int KERNEL_ELEMS = 49;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 100000;

    localparam int LANES = GB_DATA_W / DATA_W;
    localparam int WORDS_PER_KPOS = CHANNELS / LANES;
    localparam int CHANNEL_W = $clog2(CHANNELS);
    localparam int MEM_DEPTH = 1 << GB_ADDR_W;
    localparam int ACT_BASE = 17;
    localparam int WGT_BASE = 901;

    logic clk;
    logic rst_n;
    logic run_en;
    logic start;
    logic busy;
    logic done;

    logic act_rd_valid;
    logic [GB_ADDR_W-1:0] act_rd_addr;
    logic [GB_DATA_W-1:0] act_rd_data;
    logic wgt_rd_valid;
    logic [GB_ADDR_W-1:0] wgt_rd_addr;
    logic [GB_DATA_W-1:0] wgt_rd_data;

    logic psum_valid;
    logic [CHANNEL_W-1:0] psum_channel;
    logic signed [ACC_W-1:0] psum;

    logic [GB_DATA_W-1:0] act_mem [MEM_DEPTH];
    logic [GB_DATA_W-1:0] wgt_mem [MEM_DEPTH];
    logic signed [ACC_W-1:0] expected [CHANNELS];

    int fail_cnt;
    int out_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    gdconv7x7_core #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .CHANNELS(CHANNELS),
        .KERNEL_ELEMS(KERNEL_ELEMS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en),
        .start_i(start),
        .busy_o(busy),
        .done_o(done),
        .act_base_addr_i(GB_ADDR_W'(ACT_BASE)),
        .wgt_base_addr_i(GB_ADDR_W'(WGT_BASE)),
        .gb_act_rd_valid_o(act_rd_valid),
        .gb_act_rd_addr_o(act_rd_addr),
        .gb_act_rd_data_i(act_rd_data),
        .gb_wgt_rd_valid_o(wgt_rd_valid),
        .gb_wgt_rd_addr_o(wgt_rd_addr),
        .gb_wgt_rd_data_i(wgt_rd_data),
        .psum_valid_o(psum_valid),
        .psum_channel_o(psum_channel),
        .psum_o(psum)
    );

    always @(posedge clk) begin
        if (act_rd_valid) begin
            act_rd_data <= act_mem[act_rd_addr];
        end
        if (wgt_rd_valid) begin
            wgt_rd_data <= wgt_mem[wgt_rd_addr];
        end
    end

    function automatic logic signed [DATA_W-1:0] act_value(input int kpos, input int ch);
        int v;
        begin
            v = ((kpos * 11 + ch * 7 + 13) % 255) - 128;
            act_value = v[DATA_W-1:0];
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] wgt_value(input int kpos, input int ch);
        int v;
        begin
            v = ((kpos * 5 + ch * 3 + 29) % 255) - 128;
            wgt_value = v[DATA_W-1:0];
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic init_mem();
        int addr;
        int ch;
        logic [GB_DATA_W-1:0] word;
        logic signed [DATA_W-1:0] a;
        logic signed [DATA_W-1:0] w;
        begin
            for (int i = 0; i < MEM_DEPTH; i++) begin
                act_mem[i] = '0;
                wgt_mem[i] = '0;
            end
            for (int c = 0; c < CHANNELS; c++) begin
                expected[c] = '0;
            end

            for (int k = 0; k < KERNEL_ELEMS; k++) begin
                for (int cw = 0; cw < WORDS_PER_KPOS; cw++) begin
                    word = '0;
                    for (int lane = 0; lane < LANES; lane++) begin
                        ch = cw * LANES + lane;
                        a = act_value(k, ch);
                        word[lane*DATA_W +: DATA_W] = a;
                        expected[ch] += ACC_W'(a) * ACC_W'(wgt_value(k, ch));
                    end
                    addr = ACT_BASE + k * WORDS_PER_KPOS + cw;
                    act_mem[addr] = word;

                    word = '0;
                    for (int lane = 0; lane < LANES; lane++) begin
                        ch = cw * LANES + lane;
                        w = wgt_value(k, ch);
                        word[lane*DATA_W +: DATA_W] = w;
                    end
                    addr = WGT_BASE + k * WORDS_PER_KPOS + cw;
                    wgt_mem[addr] = word;
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            check(act_rd_valid == wgt_rd_valid, "activation and weight read valid should match");
            if (act_rd_valid) begin
                check(act_rd_addr >= ACT_BASE, $sformatf("act addr underflow %0d", act_rd_addr));
                check(act_rd_addr < ACT_BASE + KERNEL_ELEMS * WORDS_PER_KPOS,
                      $sformatf("act addr overflow %0d", act_rd_addr));
                check(wgt_rd_addr >= WGT_BASE, $sformatf("wgt addr underflow %0d", wgt_rd_addr));
                check(wgt_rd_addr < WGT_BASE + KERNEL_ELEMS * WORDS_PER_KPOS,
                      $sformatf("wgt addr overflow %0d", wgt_rd_addr));
                check((act_rd_addr - ACT_BASE) == (wgt_rd_addr - WGT_BASE),
                      $sformatf("act/wgt address offsets differ act=%0d wgt=%0d", act_rd_addr, wgt_rd_addr));
            end

            if (psum_valid) begin
                check(psum_channel == CHANNEL_W'(out_cnt),
                      $sformatf("channel order expected %0d got %0d", out_cnt, psum_channel));
                check(psum === expected[out_cnt],
                      $sformatf("psum mismatch ch=%0d expected=%0d got=%0d",
                                out_cnt, expected[out_cnt], psum));
                out_cnt++;
            end
        end
    end

    initial begin
        fail_cnt = 0;
        out_cnt = 0;
        rst_n = 1'b0;
        run_en = 1'b1;
        start = 1'b0;
        act_rd_data = '0;
        wgt_rd_data = '0;

        init_mem();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        wait (done === 1'b1);
        @(posedge clk);

        check(out_cnt == CHANNELS, $sformatf("expected %0d outputs, got %0d", CHANNELS, out_cnt));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] gdconv7x7_core FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] gdconv7x7_core PASSED outputs=%0d", out_cnt);
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
