`timescale 1ns/1ps

module tb_array_level2_top;
    parameter int ROW   = 3;
    parameter int COL   = 4;
    parameter int CIN   = 5;
    parameter int NUM_TILES = 3;
    parameter int DATA_W = 8;
    parameter int ACC_W  = 32;
    parameter int K_MAX  = CIN;
    parameter int COUNT_W = 16;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 10000;

    localparam int BUF_NUM = 2;
    localparam int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX);
    localparam int MAX_RC = (ROW > COL) ? ROW : COL;
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC);

    logic clk;
    logic rst_n;
    logic start_i;
    logic done_o;
    logic [K_ADDR_W:0] k_size_i;

    logic wr_en_i [BUF_NUM];
    logic [BANK_ADDR_W-1:0] wr_bank_i [BUF_NUM];
    logic [K_ADDR_W-1:0] wr_idx_i [BUF_NUM];
    logic signed [DATA_W-1:0] wr_data_i [BUF_NUM];

    logic valid_o [ROW][COL];
    logic signed [ACC_W-1:0] mac_o [ROW][COL];

    logic signed [DATA_W-1:0] act_mem [NUM_TILES*ROW*CIN];
    logic signed [DATA_W-1:0] wgt_mem [NUM_TILES*CIN*COL];
    logic signed [ACC_W-1:0] golden_mac [NUM_TILES*ROW*COL];

    integer pass_cnt;
    integer fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    initial $readmemh("gold_models/array_level2_activation.hex", act_mem);
    initial $readmemh("gold_models/array_level2_weight.hex", wgt_mem);
    initial $readmemh("gold_models/array_level2_golden.hex", golden_mac);

    array_level2_top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .COUNT_W(COUNT_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .BUF_NUM(BUF_NUM)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en_i(wr_en_i),
        .wr_bank_i(wr_bank_i),
        .wr_idx_i(wr_idx_i),
        .wr_data_i(wr_data_i),
        .k_size_i(k_size_i),
        .start_i(start_i),
        .done_o(done_o),
        .valid_o(valid_o),
        .mac_o(mac_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $fatal(1, "[TB] array_level2_top FAILED");
        end
    endtask

    task automatic clear_writes();
        begin
            for (int b = 0; b < BUF_NUM; b++) begin
                wr_en_i[b]   = 1'b0;
                wr_bank_i[b] = '0;
                wr_idx_i[b]  = '0;
                wr_data_i[b] = '0;
            end
        end
    endtask

    task automatic preload_tile(input int tile);
        int max_entries;
        int act_base;
        int wgt_base;
        int act_row;
        int act_k;
        int wgt_k;
        int wgt_col;
        begin
            max_entries = (ROW*CIN > CIN*COL) ? ROW*CIN : CIN*COL;
            act_base = tile * ROW * CIN;
            wgt_base = tile * CIN * COL;

            for (int n = 0; n < max_entries; n++) begin
                @(negedge clk);
                clear_writes();

                if (n < ROW*CIN) begin
                    act_row = n / CIN;
                    act_k   = n % CIN;
                    wr_en_i[0]   = 1'b1;
                    wr_bank_i[0] = act_row[BANK_ADDR_W-1:0];
                    wr_idx_i[0]  = act_k[K_ADDR_W-1:0];
                    wr_data_i[0] = act_mem[act_base + act_row*CIN + act_k];
                end

                if (n < CIN*COL) begin
                    wgt_k   = n / COL;
                    wgt_col = n % COL;
                    wr_en_i[1]   = 1'b1;
                    wr_bank_i[1] = wgt_col[BANK_ADDR_W-1:0];
                    wr_idx_i[1]  = wgt_k[K_ADDR_W-1:0];
                    wr_data_i[1] = wgt_mem[wgt_base + wgt_k*COL + wgt_col];
                end

                @(posedge clk);
            end

            @(negedge clk);
            clear_writes();
        end
    endtask

    task automatic start_tile();
        begin
            @(negedge clk);
            start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start_i = 1'b0;
        end
    endtask

    task automatic compare_tile(input int tile);
        int golden_base;
        begin
            golden_base = tile * ROW * COL;

            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    if (valid_o[r][c] !== 1'b1) begin
                        fail_cnt++;
                        $error("[FAIL] tile %0d valid_o[%0d][%0d] is not high at done", tile, r, c);
                    end else if (mac_o[r][c] === golden_mac[golden_base + r*COL + c]) begin
                        pass_cnt++;
                        $display("[PASS] tile %0d mac_o[%0d][%0d] = %0d (0x%08h)",
                                 tile, r, c, mac_o[r][c], mac_o[r][c]);
                    end else begin
                        fail_cnt++;
                        $error("[FAIL] tile %0d mac_o[%0d][%0d] expected %0d (0x%08h), got %0d (0x%08h)",
                               tile, r, c,
                               golden_mac[golden_base + r*COL + c],
                               golden_mac[golden_base + r*COL + c],
                               mac_o[r][c],
                               mac_o[r][c]);
                    end
                end
            end
        end
    endtask

    task automatic fake_relu_10_cycles();
        begin
            repeat (10) @(posedge clk);
        end
    endtask

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 1'b0;
        start_i = 1'b0;
        k_size_i = CIN[K_ADDR_W:0];
        clear_writes();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("[TB] start array_level2_top test ROW=%0d COL=%0d CIN=%0d NUM_TILES=%0d",
                 ROW, COL, CIN, NUM_TILES);

        for (int tile = 0; tile < NUM_TILES; tile++) begin
            $display("[TB] preload tile %0d", tile);
            preload_tile(tile);

            $display("[TB] start tile %0d", tile);
            start_tile();

            wait (done_o === 1'b1);
            #1;
            $display("[TB] done tile %0d", tile);
            compare_tile(tile);
            check(fail_cnt == 0, $sformatf("tile %0d compare failed", tile));

            fake_relu_10_cycles();
        end

        $display("[TB] array_level2_top compare done: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $display("[TB] array_level2_top PASSED");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
