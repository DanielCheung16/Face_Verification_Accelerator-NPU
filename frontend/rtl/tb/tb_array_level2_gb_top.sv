`timescale 1ns/1ps

module tb_array_level2_gb_top;
    parameter int ROW   = 14;
    parameter int COL   = 16;
    parameter int K_MAX = 512;
    parameter int SINGLE_CASE = 0;
    parameter int M_SIZE = 3;
    parameter int K_SIZE = 5;
    parameter int N_SIZE = 4;
    parameter int M_MAX = 32;
    parameter int N_MAX = 64;
    parameter int DATA_W = 8;
    parameter int ACC_W  = 32;
    parameter int COUNT_W = 16;
    parameter int STALL_MODE = 0;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 2000000;

    localparam int BUF_NUM = 2;
    localparam int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX);

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic preload_start_i;
    logic preload_busy_o;
    logic preload_done_o;
    logic compute_start_i;
    logic compute_done_o;

    logic [K_ADDR_W:0] k_size_i;
    logic [15:0] m_size_i;
    logic [15:0] n_size_i;
    logic [15:0] row_base_i;
    logic [15:0] col_base_i;

    logic gb_act_rd_valid_o;
    logic [31:0] gb_act_rd_addr_o;
    logic signed [DATA_W-1:0] gb_act_rd_data_i;
    logic gb_wgt_rd_valid_o;
    logic [31:0] gb_wgt_rd_addr_o;
    logic signed [DATA_W-1:0] gb_wgt_rd_data_i;

    logic valid_o [ROW][COL];
    logic signed [ACC_W-1:0] mac_o [ROW][COL];

    logic signed [DATA_W-1:0] act_mem [M_MAX*K_MAX];
    logic signed [DATA_W-1:0] wgt_mem [K_MAX*N_MAX];

    int pass_cnt;
    int fail_cnt;
    int active_phase;
    int stall_count;
    int case_id;
    int cur_m;
    int cur_k;
    int cur_n;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    array_level2_gb_top #(
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
        .preload_start_i(preload_start_i),
        .preload_busy_o(preload_busy_o),
        .preload_done_o(preload_done_o),
        .compute_start_i(compute_start_i),
        .compute_done_o(compute_done_o),
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
            run_en_i <= ((stall_count % 9) != 8);
            stall_count <= stall_count + 1;
        end else begin
            run_en_i <= 1'b1;
            stall_count <= 0;
        end
    end

    function automatic logic signed [DATA_W-1:0] act_value(input int row, input int k, input int cid);
        int v;
        begin
            v = ((row * 5 + k * 3 + cid) % 15) - 7;
            act_value = v[DATA_W-1:0];
        end
    endfunction

    function automatic logic signed [DATA_W-1:0] wgt_value(input int k, input int col, input int cid);
        int v;
        begin
            v = ((k * 7 + col * 2 + cid * 3) % 13) - 6;
            wgt_value = v[DATA_W-1:0];
        end
    endfunction

    function automatic logic signed [ACC_W-1:0] golden_value(input int row, input int col);
        logic signed [ACC_W-1:0] acc;
        begin
            acc = '0;
            for (int k = 0; k < cur_k; k++) begin
                acc += act_mem[row*cur_k + k] * wgt_mem[k*cur_n + col];
            end
            golden_value = acc;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $error("%s", msg);
            $fatal(1, "[TB] array_level2_gb_top FAILED");
        end
    endtask

    task automatic wait_run_enabled();
        begin
            while (run_en_i !== 1'b1) begin
                @(negedge clk);
            end
        end
    endtask

    task automatic pulse_preload_start();
        begin
            active_phase = 1;
            wait_run_enabled();
            @(negedge clk);
            preload_start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            preload_start_i = 1'b0;
            wait (preload_done_o === 1'b1);
            #1;
            check(preload_busy_o === 1'b0, "preload_busy_o should be low when preload_done_o is high");
            active_phase = 0;
        end
    endtask

    task automatic pulse_compute_start();
        begin
            active_phase = 1;
            wait_run_enabled();
            @(negedge clk);
            compute_start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            compute_start_i = 1'b0;
            wait (compute_done_o === 1'b1);
            #1;
            active_phase = 0;
        end
    endtask

    task automatic init_case(input int m, input int k_size, input int n, input int cid);
        begin
            cur_m = m;
            cur_k = k_size;
            cur_n = n;

            check(m <= M_MAX, $sformatf("M=%0d exceeds M_MAX=%0d", m, M_MAX));
            check(k_size <= K_MAX, $sformatf("K=%0d exceeds K_MAX=%0d", k_size, K_MAX));
            check(n <= N_MAX, $sformatf("N=%0d exceeds N_MAX=%0d", n, N_MAX));

            for (int i = 0; i < M_MAX*K_MAX; i++) begin
                act_mem[i] = '0;
            end
            for (int i = 0; i < K_MAX*N_MAX; i++) begin
                wgt_mem[i] = '0;
            end

            for (int r = 0; r < m; r++) begin
                for (int kk = 0; kk < k_size; kk++) begin
                    act_mem[r*k_size + kk] = act_value(r, kk, cid);
                end
            end
            for (int kk = 0; kk < k_size; kk++) begin
                for (int c = 0; c < n; c++) begin
                    wgt_mem[kk*n + c] = wgt_value(kk, c, cid);
                end
            end

            k_size_i = k_size[K_ADDR_W:0];
            m_size_i = m[15:0];
            n_size_i = n[15:0];
        end
    endtask

    task automatic compare_tile(input int mt, input int nt);
        int global_row;
        int global_col;
        logic signed [ACC_W-1:0] exp;
        begin
            for (int r = 0; r < ROW; r++) begin
                for (int c = 0; c < COL; c++) begin
                    global_row = mt*ROW + r;
                    global_col = nt*COL + c;
                    if ((global_row < cur_m) && (global_col < cur_n)) begin
                        exp = golden_value(global_row, global_col);
                        if (valid_o[r][c] !== 1'b1) begin
                            fail_cnt++;
                            $error("[FAIL] valid_o[%0d][%0d] low at done for C[%0d][%0d]",
                                   r, c, global_row, global_col);
                        end else if (mac_o[r][c] === exp) begin
                            pass_cnt++;
                        end else begin
                            fail_cnt++;
                            $error("[FAIL] case=%0d C[%0d][%0d] expected %0d (0x%08h), got %0d (0x%08h)",
                                   case_id, global_row, global_col, exp, exp, mac_o[r][c], mac_o[r][c]);
                        end
                    end
                end
            end
        end
    endtask

    task automatic run_case(input int m, input int k_size, input int n);
        int num_m_tiles;
        int num_n_tiles;
        begin
            case_id++;
            init_case(m, k_size, n, case_id);
            num_m_tiles = (m + ROW - 1) / ROW;
            num_n_tiles = (n + COL - 1) / COL;

            $display("[TB] case %0d: M=%0d K=%0d N=%0d, tiles M=%0d N=%0d",
                     case_id, m, k_size, n, num_m_tiles, num_n_tiles);

            for (int mt = 0; mt < num_m_tiles; mt++) begin
                for (int nt = 0; nt < num_n_tiles; nt++) begin
                    row_base_i = mt*ROW;
                    col_base_i = nt*COL;

                    pulse_preload_start();
                    pulse_compute_start();
                    compare_tile(mt, nt);
                    check(fail_cnt == 0, $sformatf("case=%0d tile mt=%0d nt=%0d compare failed", case_id, mt, nt));

                    repeat (3) @(posedge clk);
                end
            end
        end
    endtask

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        active_phase = 0;
        stall_count = 0;
        case_id = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        preload_start_i = 1'b0;
        compute_start_i = 1'b0;
        k_size_i = '0;
        m_size_i = '0;
        n_size_i = '0;
        row_base_i = '0;
        col_base_i = '0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("[TB] start array_level2_gb_top ROW=%0d COL=%0d K_MAX=%0d STALL_MODE=%0d",
                 ROW, COL, K_MAX, STALL_MODE);

        if (SINGLE_CASE) begin
            run_case(M_SIZE, K_SIZE, N_SIZE);
        end else begin
            run_case(1, 1, 1);
            run_case(3, 5, 4);
            run_case(14, 64, 16);
            run_case(17, 128, 33);
            run_case(28, 512, 32);
        end

        $display("[TB] array_level2_gb_top PASSED STALL_MODE=%0d pass=%0d fail=%0d",
                 STALL_MODE, pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
