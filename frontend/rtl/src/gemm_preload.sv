/*
 * GEMM tile preload bridge.
 *
 * This module owns the global-buffer read address generation for one output
 * tile and writes the returned data into the local activation/weight banked
 * buffers used by array_level2_top.
 *
 * A address: A[row][k] -> row * K + k
 * B address: B[k][col] -> k * N + col
 */
module gemm_preload #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int K_MAX     = 512,
    parameter int DATA_W    = 8,
    parameter int DIM_W     = 16,
    parameter int GB_ADDR_W = 32,
    parameter int BUF_NUM   = 2,
    parameter int K_ADDR_W  = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    localparam int MAX_RC = (ROW > COL) ? ROW : COL,
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC),
    localparam int LOAD_COUNT_W = (ROW*K_MAX > COL*K_MAX) ? $clog2(ROW*K_MAX + 1) : $clog2(COL*K_MAX + 1)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start_i,
    input  logic run_en_i,
    output logic busy_o,
    output logic done_o,

    input  logic [DIM_W-1:0]  m_size_i,
    input  logic [K_ADDR_W:0] k_size_i,
    input  logic [DIM_W-1:0]  n_size_i,
    input  logic [DIM_W-1:0]  row_base_i,
    input  logic [DIM_W-1:0]  col_base_i,

    output logic                 gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic signed [DATA_W-1:0] gb_act_rd_data_i,

    output logic                 gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic signed [DATA_W-1:0] gb_wgt_rd_data_i,

    output logic                     wr_en_o   [BUF_NUM],
    output logic [BANK_ADDR_W-1:0]   wr_bank_o [BUF_NUM],
    output logic [K_ADDR_W-1:0]      wr_idx_o  [BUF_NUM],
    output logic signed [DATA_W-1:0] wr_data_o [BUF_NUM]
);

    typedef enum logic [1:0] {IDLE, RUN, DONE} state_t;

    state_t state;
    logic [LOAD_COUNT_W-1:0] load_count;
    logic [LOAD_COUNT_W-1:0] max_entries;

    logic gb_act_rd_valid_q;
    logic [GB_ADDR_W-1:0] gb_act_rd_addr_q;
    logic gb_wgt_rd_valid_q;
    logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_q;

    logic act_pending;
    logic act_pending_pad;
    logic [BANK_ADDR_W-1:0] act_pending_bank;
    logic [K_ADDR_W-1:0] act_pending_idx;
    logic act_write_pending;
    logic act_write_pending_pad;
    logic [BANK_ADDR_W-1:0] act_write_pending_bank;
    logic [K_ADDR_W-1:0] act_write_pending_idx;

    logic wgt_pending;
    logic wgt_pending_pad;
    logic [BANK_ADDR_W-1:0] wgt_pending_bank;
    logic [K_ADDR_W-1:0] wgt_pending_idx;
    logic wgt_write_pending;
    logic wgt_write_pending_pad;
    logic [BANK_ADDR_W-1:0] wgt_write_pending_bank;
    logic [K_ADDR_W-1:0] wgt_write_pending_idx;

    int act_row;
    int act_k;
    int wgt_k;
    int wgt_col;
    logic [DIM_W-1:0] global_row;
    logic [DIM_W-1:0] global_col;

    assign busy_o = (state == RUN);
    assign max_entries = (ROW*k_size_i > COL*k_size_i) ? ROW*k_size_i : COL*k_size_i;
    assign gb_act_rd_valid_o = run_en_i && gb_act_rd_valid_q;
    assign gb_act_rd_addr_o = gb_act_rd_addr_q;
    assign gb_wgt_rd_valid_o = run_en_i && gb_wgt_rd_valid_q;
    assign gb_wgt_rd_addr_o = gb_wgt_rd_addr_q;

    task automatic clear_write_outputs();
        begin
            for (int b = 0; b < BUF_NUM; b++) begin
                wr_en_o[b]   <= 1'b0;
                wr_bank_o[b] <= '0;
                wr_idx_o[b]  <= '0;
                wr_data_o[b] <= '0;
            end
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            load_count <= '0;
            done_o <= 1'b0;
            gb_act_rd_valid_q <= 1'b0;
            gb_act_rd_addr_q <= '0;
            gb_wgt_rd_valid_q <= 1'b0;
            gb_wgt_rd_addr_q <= '0;
            act_pending <= 1'b0;
            act_pending_pad <= 1'b0;
            act_pending_bank <= '0;
            act_pending_idx <= '0;
            act_write_pending <= 1'b0;
            act_write_pending_pad <= 1'b0;
            act_write_pending_bank <= '0;
            act_write_pending_idx <= '0;
            wgt_pending <= 1'b0;
            wgt_pending_pad <= 1'b0;
            wgt_pending_bank <= '0;
            wgt_pending_idx <= '0;
            wgt_write_pending <= 1'b0;
            wgt_write_pending_pad <= 1'b0;
            wgt_write_pending_bank <= '0;
            wgt_write_pending_idx <= '0;
            clear_write_outputs();
        end else begin
            done_o <= 1'b0;
            clear_write_outputs();

            case (state)
                IDLE: begin
                    load_count <= '0;
                    gb_act_rd_valid_q <= 1'b0;
                    gb_wgt_rd_valid_q <= 1'b0;
                    act_pending <= 1'b0;
                    wgt_pending <= 1'b0;
                    act_write_pending <= 1'b0;
                    wgt_write_pending <= 1'b0;

                    if (start_i && run_en_i) begin
`ifndef SYNTHESIS
                        if (k_size_i > K_MAX) begin
                            $error("gemm_preload k_size_i=%0d exceeds K_MAX=%0d", k_size_i, K_MAX);
                        end
`endif
                        state <= RUN;
                    end
                end

                RUN: begin
                    if (run_en_i) begin
                        gb_act_rd_valid_q <= 1'b0;
                        gb_wgt_rd_valid_q <= 1'b0;

                        if (act_write_pending) begin
                            wr_en_o[0]   <= 1'b1;
                            wr_bank_o[0] <= act_write_pending_bank;
                            wr_idx_o[0]  <= act_write_pending_idx;
                            wr_data_o[0] <= act_write_pending_pad ? '0 : gb_act_rd_data_i;
                        end

                        if (wgt_write_pending) begin
                            wr_en_o[1]   <= 1'b1;
                            wr_bank_o[1] <= wgt_write_pending_bank;
                            wr_idx_o[1]  <= wgt_write_pending_idx;
                            wr_data_o[1] <= wgt_write_pending_pad ? '0 : gb_wgt_rd_data_i;
                        end

                        act_write_pending <= act_pending;
                        act_write_pending_pad <= act_pending_pad;
                        act_write_pending_bank <= act_pending_bank;
                        act_write_pending_idx <= act_pending_idx;

                        wgt_write_pending <= wgt_pending;
                        wgt_write_pending_pad <= wgt_pending_pad;
                        wgt_write_pending_bank <= wgt_pending_bank;
                        wgt_write_pending_idx <= wgt_pending_idx;

                        act_pending <= 1'b0;
                        wgt_pending <= 1'b0;

                        if (load_count < max_entries) begin
                            if (load_count < ROW*k_size_i) begin
                                act_row = load_count / k_size_i;
                                act_k = load_count % k_size_i;
                                global_row = row_base_i + act_row[DIM_W-1:0];

                                act_pending <= 1'b1;
                                act_pending_pad <= (global_row >= m_size_i);
                                act_pending_bank <= act_row[BANK_ADDR_W-1:0];
                                act_pending_idx <= act_k[K_ADDR_W-1:0];
                                gb_act_rd_valid_q <= (global_row < m_size_i);
                                gb_act_rd_addr_q <= global_row * k_size_i + act_k;
                            end

                            if (load_count < COL*k_size_i) begin
                                wgt_k = load_count / COL;
                                wgt_col = load_count % COL;
                                global_col = col_base_i + wgt_col[DIM_W-1:0];

                                wgt_pending <= 1'b1;
                                wgt_pending_pad <= (global_col >= n_size_i);
                                wgt_pending_bank <= wgt_col[BANK_ADDR_W-1:0];
                                wgt_pending_idx <= wgt_k[K_ADDR_W-1:0];
                                gb_wgt_rd_valid_q <= (global_col < n_size_i);
                                gb_wgt_rd_addr_q <= wgt_k * n_size_i + global_col;
                            end

                            load_count <= load_count + 1'b1;
                        end else begin
                            if (!act_pending && !wgt_pending && !act_write_pending && !wgt_write_pending) begin
                                state <= DONE;
                            end
                        end
                    end
                end

                DONE: begin
                    done_o <= 1'b1;
                    if (run_en_i) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
