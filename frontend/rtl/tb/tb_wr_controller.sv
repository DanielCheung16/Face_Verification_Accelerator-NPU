`timescale 1ns/1ps

module tb_wr_controller;
    parameter int ROW = 14;
    parameter int COL = 16;
    parameter int DATA_IN_W = 8;
    parameter int DATA_OUT_W = 128;
    parameter int DIM_W = 16;
    parameter int GB_ADDR_W = 16;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 10000;

    localparam int ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW);
    localparam int GB_WORDS = 1 << GB_ADDR_W;
    localparam int OUT_BASE = 1 << (GB_ADDR_W - 1);

    logic clk;
    logic rst_n;
    logic wr_en_i;
    logic signed [DATA_IN_W-1:0] tile_data [ROW][COL];
    logic [ADDR_W-1:0] rd_addr;
    logic signed [DATA_OUT_W-1:0] wb_data;

    logic [DIM_W-1:0] n_size_i;
    logic [DIM_W-1:0] m_size_i;
    logic tile_process_done;
    logic [GB_ADDR_W-1:0] ao_addr;
    logic ao_wr_en;
    logic signed [DATA_OUT_W-1:0] ao_data;
    logic busy;
    logic done;

    logic signed [DATA_OUT_W-1:0] out_mem [GB_WORDS];
    int fail_cnt;
    int write_cnt;
    int cur_mt;
    int cur_nt;
    int nt_words;
    int mt_words;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    wb_buffer #(
        .ROW(ROW),
        .COL(COL),
        .DATA_IN_W(DATA_IN_W),
        .DATA_OUT_W(DATA_OUT_W)
    ) u_wb_buffer (
        .aclk(clk),
        .aresetn(rst_n),
        .wr_en_i(wr_en_i),
        .data_i(tile_data),
        .rd_addr_i(rd_addr),
        .data_o(wb_data)
    );

    wr_controller #(
        .ROW(ROW),
        .COL(COL),
        .DATA_OUT_W(DATA_OUT_W),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_wr_controller (
        .aclk(clk),
        .aresetn(rst_n),
        .n_size_i(n_size_i),
        .m_size_i(m_size_i),
        .tile_process_done(tile_process_done),
        .data_i(wb_data),
        .rd_addr_o(rd_addr),
        .ao_addr_o(ao_addr),
        .ao_wr_en_o(ao_wr_en),
        .ao_data_o(ao_data),
        .busy_o(busy),
        .done_o(done)
    );

    always @(posedge clk) begin
        if (ao_wr_en) begin
            out_mem[ao_addr] <= ao_data;
            write_cnt <= write_cnt + 1;
        end
    end

    function automatic logic signed [DATA_IN_W-1:0] value_for(
        input int mt,
        input int nt,
        input int r,
        input int c
    );
        int v;
        begin
            v = ((mt * 37 + nt * 19 + r * 5 + c * 3) % 255) - 128;
            value_for = v[DATA_IN_W-1:0];
        end
    endfunction

    function automatic logic signed [DATA_OUT_W-1:0] packed_row(
        input int mt,
        input int nt,
        input int r
    );
        logic signed [DATA_OUT_W-1:0] word;
        begin
            word = '0;
            for (int c = 0; c < COL; c++) begin
                word[c*DATA_IN_W +: DATA_IN_W] = value_for(mt, nt, r, c);
            end
            packed_row = word;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic load_tile(input int mt, input int nt);
        begin
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    tile_data[r][c] = value_for(mt, nt, r, c);
                end
            end

            @(negedge clk);
            wr_en_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            wr_en_i = 1'b0;
        end
    endtask

    task automatic writeback_tile();
        begin
            @(negedge clk);
            tile_process_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tile_process_done = 1'b0;
            wait (done === 1'b1);
            @(posedge clk);
        end
    endtask

    task automatic verify_output(input int m, input int n);
        int global_row;
        int global_col_base;
        int addr;
        logic signed [DATA_OUT_W-1:0] exp;
        begin
            nt_words = (n + COL - 1) / COL;
            mt_words = (m + ROW - 1) / ROW;
            for (int mt = 0; mt < mt_words; mt++) begin
                for (int nt = 0; nt < nt_words; nt++) begin
                    for (int r = 0; r < ROW; r++) begin
                        global_row = mt*ROW + r;
                        global_col_base = nt*COL;
                        addr = OUT_BASE + global_row*nt_words + nt;
                        if (global_row < m) begin
                            exp = packed_row(mt, nt, r);
                            check(out_mem[addr] === exp,
                                  $sformatf("addr %0d row %0d col_base %0d expected 0x%032h got 0x%032h",
                                            addr, global_row, global_col_base, exp, out_mem[addr]));
                        end
                    end
                end
            end
        end
    endtask

    task automatic run_case(input int m, input int n);
        int expected_writes;
        begin
            n_size_i = n[DIM_W-1:0];
            m_size_i = m[DIM_W-1:0];
            nt_words = (n + COL - 1) / COL;
            mt_words = (m + ROW - 1) / ROW;
            expected_writes = m * nt_words;
            write_cnt = 0;

            for (int i = 0; i < GB_WORDS; i++) begin
                out_mem[i] = '0;
            end

            $display("[TB] wr_controller case M=%0d N=%0d mt=%0d nt=%0d",
                     m, n, mt_words, nt_words);

            for (cur_nt = 0; cur_nt < nt_words; cur_nt++) begin
                for (cur_mt = 0; cur_mt < mt_words; cur_mt++) begin
                    load_tile(cur_mt, cur_nt);
                    writeback_tile();
                    repeat (2) @(posedge clk);
                end
            end

            check(write_cnt == expected_writes,
                  $sformatf("expected %0d writes, got %0d", expected_writes, write_cnt));
            verify_output(m, n);
        end
    endtask

    initial begin
        fail_cnt = 0;
        write_cnt = 0;
        rst_n = 1'b0;
        wr_en_i = 1'b0;
        tile_process_done = 1'b0;
        n_size_i = '0;
        m_size_i = '0;
        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                tile_data[r][c] = '0;
            end
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_case(1, 1);
        run_case(7, 16);
        run_case(14, 16);
        run_case(17, 33);
        run_case(30, 49);
        run_case(29, 49);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] wr_controller FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] wr_controller PASSED");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
