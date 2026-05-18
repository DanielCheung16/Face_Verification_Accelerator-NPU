`timescale 1ns/1ps

module tb_gdconv7x7_param_wb;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int DATA_W = 8;
    parameter int GB_DATA_W = 128;
    parameter int GB_ADDR_W = 12;
    parameter int PARAM_ADDR_W = 8;
    parameter int CHANNELS = 40;
    parameter int ELEM_CNT_W = 10;
    parameter int MUL_W = 32;
    parameter int SHIFT_W = 6;
    parameter int BIAS_SHIFT = 16;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 5000;

    localparam int LANES = GB_DATA_W / DATA_W;
    localparam int MASK_W = LANES;
    localparam int CHANNEL_W = $clog2(CHANNELS);
    localparam int OUT_BASE = 123;
    localparam int COMMON_BASE = 17;
    localparam int OUTPUT_ELEMENTS = 35;
    localparam int OUT_WORDS = (OUTPUT_ELEMENTS + LANES - 1) / LANES;

    logic clk;
    logic rst_n;
    logic start;
    logic signed [ACC_W-1:0] output_zero_point;

    logic psum_valid;
    logic [CHANNEL_W-1:0] psum_channel;
    logic signed [ACC_W-1:0] psum;

    logic common_rd_en;
    logic [PARAM_ADDR_W-1:0] common_rd_addr;
    logic common_rd_valid;
    logic signed [BIAS_W-1:0] param_bias;
    logic signed [MUL_W-1:0] param_mult;
    logic [SHIFT_W-1:0] param_shift;

    logic sched_valid;
    logic [CHANNEL_W-1:0] sched_channel;
    logic signed [ACC_W-1:0] sched_psum;
    logic signed [BIAS_W-1:0] sched_bias;
    logic signed [MUL_W-1:0] sched_mult;
    logic [SHIFT_W-1:0] sched_shift;

    logic wr_valid;
    logic [GB_ADDR_W-1:0] wr_addr;
    logic [GB_DATA_W-1:0] wr_data;
    logic [MASK_W-1:0] wr_mask;
    logic busy;
    logic done;

    logic signed [BIAS_W-1:0] bias_mem [CHANNELS];
    logic signed [MUL_W-1:0] mult_mem [CHANNELS];
    logic [SHIFT_W-1:0] shift_mem [CHANNELS];
    logic [GB_DATA_W-1:0] expected_word [OUT_WORDS];
    logic [MASK_W-1:0] expected_mask [OUT_WORDS];
    int fail_cnt;
    int write_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    gdconv7x7_param_scheduler #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .CHANNELS(CHANNELS)
    ) u_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start),
        .common_param_base_i(PARAM_ADDR_W'(COMMON_BASE)),
        .psum_valid_i(psum_valid),
        .psum_channel_i(psum_channel),
        .psum_i(psum),
        .common_rd_en_o(common_rd_en),
        .common_rd_addr_o(common_rd_addr),
        .common_rd_valid_i(common_rd_valid),
        .param_bias_i(param_bias),
        .param_requant_multiplier_i(param_mult),
        .param_requant_shift_i(param_shift),
        .valid_o(sched_valid),
        .channel_o(sched_channel),
        .psum_o(sched_psum),
        .bias_o(sched_bias),
        .requant_multiplier_o(sched_mult),
        .requant_shift_o(sched_shift)
    );

    gdconv7x7_wb #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W),
        .BIAS_SHIFT(BIAS_SHIFT)
    ) u_wb (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start),
        .out_base_addr_i(GB_ADDR_W'(OUT_BASE)),
        .output_elements_i(ELEM_CNT_W'(OUTPUT_ELEMENTS)),
        .output_zero_point_i(output_zero_point),
        .psum_i(sched_psum),
        .valid_i(sched_valid),
        .bias_i(sched_bias),
        .requant_multiplier_i(sched_mult),
        .requant_shift_i(sched_shift),
        .gb_ao_wr_valid_o(wr_valid),
        .gb_ao_wr_addr_o(wr_addr),
        .gb_ao_wr_data_o(wr_data),
        .gb_ao_wr_mask_o(wr_mask),
        .busy_o(busy),
        .done_o(done)
    );

    function automatic logic signed [ACC_W-1:0] psum_value(input int ch);
        int v;
        begin
            v = ((ch * 37 + 19) % 4096) - 2048;
            psum_value = v[ACC_W-1:0];
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] expected_byte(input int ch);
        longint signed value;
        longint signed product;
        longint signed rounded;
        longint signed shifted;
        int total_shift;
        begin
            total_shift = int'(shift_mem[ch]) + BIAS_SHIFT;
            value = (longint'(psum_value(ch)) <<< BIAS_SHIFT) + longint'(bias_mem[ch]);
            product = value * longint'(mult_mem[ch]);
            if (total_shift == 0) begin
                rounded = product;
            end else begin
                rounded = product + (64'sd1 <<< (total_shift - 1));
            end
            shifted = (rounded >>> total_shift) + longint'(output_zero_point);
            if (shifted > 127) begin
                expected_byte = DATA_W'(8'sh7f);
            end else if (shifted < -128) begin
                expected_byte = DATA_W'(8'sh80);
            end else begin
                expected_byte = shifted[DATA_W-1:0];
            end
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic init_expected();
        begin
            output_zero_point = -ACC_W'(11);
            for (int ch = 0; ch < CHANNELS; ch++) begin
                bias_mem[ch] = BIAS_W'(((ch * 53 + 7) % 8192) - 4096);
                mult_mem[ch] = MUL_W'(12000 + ch * 17);
                shift_mem[ch] = SHIFT_W'(7 + (ch % 3));
            end
            for (int w = 0; w < OUT_WORDS; w++) begin
                expected_word[w] = '0;
                expected_mask[w] = '0;
            end
            for (int ch = 0; ch < OUTPUT_ELEMENTS; ch++) begin
                expected_word[ch / LANES][(ch % LANES)*DATA_W +: DATA_W] = expected_byte(ch);
                expected_mask[ch / LANES][ch % LANES] = 1'b1;
            end
        end
    endtask

    always @(posedge clk) begin
        common_rd_valid <= common_rd_en;
        if (common_rd_en) begin
            check(common_rd_addr >= COMMON_BASE, $sformatf("param addr underflow %0d", common_rd_addr));
            check(common_rd_addr < COMMON_BASE + CHANNELS,
                  $sformatf("param addr overflow %0d", common_rd_addr));
            param_bias <= bias_mem[common_rd_addr - PARAM_ADDR_W'(COMMON_BASE)];
            param_mult <= mult_mem[common_rd_addr - PARAM_ADDR_W'(COMMON_BASE)];
            param_shift <= shift_mem[common_rd_addr - PARAM_ADDR_W'(COMMON_BASE)];
        end
    end

    always @(posedge clk) begin
        if (rst_n && sched_valid) begin
            check(sched_channel < OUTPUT_ELEMENTS,
                  $sformatf("scheduler emitted unexpected channel %0d", sched_channel));
        end

        if (rst_n && wr_valid) begin
            check(write_cnt < OUT_WORDS, $sformatf("too many writes, count=%0d", write_cnt));
            if (write_cnt < OUT_WORDS) begin
                check(wr_addr == GB_ADDR_W'(OUT_BASE + write_cnt),
                      $sformatf("write addr expected %0d got %0d", OUT_BASE + write_cnt, wr_addr));
                check(wr_data === expected_word[write_cnt],
                      $sformatf("write data word=%0d expected=0x%032h got=0x%032h",
                                write_cnt, expected_word[write_cnt], wr_data));
                check(wr_mask === expected_mask[write_cnt],
                      $sformatf("write mask word=%0d expected=0x%04h got=0x%04h",
                                write_cnt, expected_mask[write_cnt], wr_mask));
            end
            write_cnt++;
        end
    end

    initial begin
        fail_cnt = 0;
        write_cnt = 0;
        rst_n = 1'b0;
        start = 1'b0;
        psum_valid = 1'b0;
        psum_channel = '0;
        psum = '0;
        common_rd_valid = 1'b0;
        param_bias = '0;
        param_mult = '0;
        param_shift = '0;

        init_expected();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        repeat (2) @(posedge clk);
        for (int ch = 0; ch < OUTPUT_ELEMENTS; ch++) begin
            @(negedge clk);
            psum_valid = 1'b1;
            psum_channel = CHANNEL_W'(ch);
            psum = psum_value(ch);
        end
        @(negedge clk);
        psum_valid = 1'b0;
        psum_channel = '0;
        psum = '0;

        wait (done === 1'b1);
        @(posedge clk);

        check(write_cnt == OUT_WORDS, $sformatf("expected %0d writes, got %0d", OUT_WORDS, write_cnt));
        if (fail_cnt != 0) begin
            $fatal(1, "[TB] gdconv7x7_param_wb FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] gdconv7x7_param_wb PASSED writes=%0d", write_cnt);
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
