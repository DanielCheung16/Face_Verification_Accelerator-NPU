`ifdef ENABLE_OLD_ARRAY_LEVEL2_TOP_TB
`timescale 1ns/1ps

module tb_array_level2_top;
    parameter int ROW   = 14;
    parameter int COL   = 16;
    parameter int K_MAX = 512;
    parameter int M_SIZE = 7;
    parameter int K_SIZE = 512;
    parameter int N_SIZE = 128;
    parameter int DATA_W = 8;
    parameter int ACC_W  = 32;
    parameter int COUNT_W = 16;
    parameter int STALL_MODE = 0;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 10000000;

    localparam int BUF_NUM = 2;
    localparam int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX);
    localparam int MAX_RC = (ROW > COL) ? ROW : COL;
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC);
    localparam int NUM_M_TILES = (M_SIZE + ROW - 1) / ROW;
    localparam int NUM_N_TILES = (N_SIZE + COL - 1) / COL;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic use_loader_i;
    logic loader_start_i;
    logic start_i;
    logic done_o;
    logic loader_busy_o;
    logic loader_done_o;

    logic [K_ADDR_W:0] k_size_i;
    logic [15:0] m_size_i;
    logic [15:0] n_size_i;
    logic [15:0] row_base_i;
    logic [15:0] col_base_i;

    logic wr_en_i [BUF_NUM];
    logic [BANK_ADDR_W-1:0] wr_bank_i [BUF_NUM];
    logic [K_ADDR_W-1:0] wr_idx_i [BUF_NUM];
    logic signed [DATA_W-1:0] wr_data_i [BUF_NUM];

    logic gb_act_rd_valid_o;
    logic [31:0] gb_act_rd_addr_o;
    logic signed [DATA_W-1:0] gb_act_rd_data_i;
    logic gb_wgt_rd_valid_o;
    logic [31:0] gb_wgt_rd_addr_o;
    logic signed [DATA_W-1:0] gb_wgt_rd_data_i;

    logic valid_o [ROW][COL];
    logic signed [ACC_W-1:0] mac_o [ROW][COL];

    logic signed [DATA_W-1:0] act_mem [M_SIZE*K_SIZE];
    logic signed [DATA_W-1:0] wgt_mem [K_SIZE*N_SIZE];
    logic signed [ACC_W-1:0] golden_mac [M_SIZE*N_SIZE];

    integer pass_cnt;
    integer fail_cnt;
    integer active_phase;
    integer stall_count;

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
        .run_en_i(run_en_i),
        .use_loader_i(use_loader_i),
        .loader_start_i(loader_start_i),
        .wr_en_i(wr_en_i),
        .wr_bank_i(wr_bank_i),
        .wr_idx_i(wr_idx_i),
        .wr_data_i(wr_data_i),
        .k_size_i(k_size_i),
        .m_size_i(m_size_i),
        .n_size_i(n_size_i),
        .row_base_i(row_base_i),
        .col_base_i(col_base_i),
        .gb_act_rd_valid_o(gb_act_rd_valid_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_valid_o(gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .start_i(start_i),
        .done_o(done_o),
        .loader_busy_o(loader_busy_o),
        .loader_done_o(loader_done_o),
        .valid_o(valid_o),
        .mac_o(mac_o)
    );

    always_ff @(posedge clk) begin
        if (gb_act_rd_valid_o) begin
            gb_act_rd_data_i <= act_mem[gb_act_rd_addr_o];
        end
        if (gb_wgt_rd_valid_o) begin
            gb_wgt_rd_data_i <= wgt_mem[gb_wgt_rd_addr_o];
        end
    end

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_en_i <= 1'b1;
            stall_count <= 0;
        end else if (STALL_MODE && active_phase) begin
            run_en_i <= ((stall_count % 7) != 6);
            stall_count <= stall_count + 1;
        end else begin
            run_en_i <= 1'b1;
            stall_count <= 0;
        end
    end

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $fatal(1, "[TB] array_level2_top FAILED");
        end
    endtask

    task automatic clear_external_writes();
        begin
            for (int b = 0; b < BUF_NUM; b++) begin
                wr_en_i[b]   = 1'b0;
                wr_bank_i[b] = '0;
                wr_idx_i[b]  = '0;
                wr_data_i[b] = '0;
            end
        end
    endtask

    task automatic wait_run_enabled();
        begin
            while (run_en_i !== 1'b1) begin
                @(negedge clk);
            end
        end
    endtask

    task automatic pulse_loader_start();
        begin
            active_phase = 1;
            wait_run_enabled();
            @(negedge clk);
            loader_start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            loader_start_i = 1'b0;
            wait (loader_done_o === 1'b1);
            #1;
            check(loader_busy_o === 1'b0, "loader_busy_o should be low with loader_done_o");
            active_phase = 0;
        end
    endtask

    task automatic pulse_compute_start();
        begin
            active_phase = 1;
            wait_run_enabled();
            @(negedge clk);
            start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start_i = 1'b0;
            wait (done_o === 1'b1);
            #1;
            active_phase = 0;
        end
    endtask

    task automatic compare_tile(input int m_tile, input int n_tile);
        int global_row;
        int global_col;
        begin
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    global_row = m_tile*ROW + r;
                    global_col = n_tile*COL + c;

                    if ((global_row < M_SIZE) && (global_col < N_SIZE)) begin
                        if (valid_o[r][c] !== 1'b1) begin
                            fail_cnt++;
                            $error("[FAIL] valid_o[%0d][%0d] low at done for C[%0d][%0d]",
                                   r, c, global_row, global_col);
                        end else if (mac_o[r][c] === golden_mac[global_row*N_SIZE + global_col]) begin
                            pass_cnt++;
                        end else begin
                            fail_cnt++;
                            $error("[FAIL] C[%0d][%0d] expected %0d (0x%08h), got %0d (0x%08h)",
                                   global_row, global_col,
                                   golden_mac[global_row*N_SIZE + global_col],
                                   golden_mac[global_row*N_SIZE + global_col],
                                   mac_o[r][c],
                                   mac_o[r][c]);
                        end
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
        active_phase = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        use_loader_i = 1'b1;
        loader_start_i = 1'b0;
        start_i = 1'b0;
        k_size_i = K_SIZE[K_ADDR_W:0];
        m_size_i = M_SIZE[15:0];
        n_size_i = N_SIZE[15:0];
        row_base_i = '0;
        col_base_i = '0;
        clear_external_writes();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("[TB] start array_level2_top loader test ROW=%0d COL=%0d K_MAX=%0d M=%0d K=%0d N=%0d STALL_MODE=%0d",
                 ROW, COL, K_MAX, M_SIZE, K_SIZE, N_SIZE, STALL_MODE);

        for (int mt = 0; mt < NUM_M_TILES; mt++) begin
            for (int nt = 0; nt < NUM_N_TILES; nt++) begin
                row_base_i = mt*ROW;
                col_base_i = nt*COL;

                $display("[TB] load tile mt=%0d nt=%0d row_base=%0d col_base=%0d", mt, nt, row_base_i, col_base_i);
                pulse_loader_start();

                $display("[TB] compute tile mt=%0d nt=%0d", mt, nt);
                pulse_compute_start();
                compare_tile(mt, nt);
                check(fail_cnt == 0, $sformatf("tile mt=%0d nt=%0d compare failed", mt, nt));

                fake_relu_10_cycles();
            end
        end

        check(pass_cnt == M_SIZE*N_SIZE, $sformatf("expected %0d compared outputs, got %0d", M_SIZE*N_SIZE, pass_cnt));
        $display("[TB] array_level2_top PASSED STALL_MODE=%0d pass=%0d fail=%0d", STALL_MODE, pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
`endif
