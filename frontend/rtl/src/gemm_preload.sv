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
    parameter int GB_DATA_W = DATA_W,
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
    input  logic [GB_ADDR_W-1:0] act_base_addr_i,
    input  logic [GB_ADDR_W-1:0] wgt_base_addr_i,

    output logic                 gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0] gb_act_rd_data_i,

    output logic                 gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0] gb_wgt_rd_data_i,

    output logic                     wr_en_o   [BUF_NUM],
    output logic [BANK_ADDR_W-1:0]   wr_bank_o [BUF_NUM],
    output logic [K_ADDR_W-1:0]      wr_idx_o  [BUF_NUM],
    output logic signed [DATA_W-1:0] wr_data_o [BUF_NUM]
);
    localparam int GB_LANES = (GB_DATA_W + DATA_W - 1) / DATA_W;
    localparam int LANE_W = (GB_LANES <= 1) ? 1 : $clog2(GB_LANES);
    localparam int K_COUNT_W = K_ADDR_W + 1;

    typedef enum logic [1:0] {IDLE, RUN, DONE} state_t;

    state_t state;
    logic [LOAD_COUNT_W-1:0] load_count;
    logic [LOAD_COUNT_W-1:0] max_entries_w;

    // These counters replace the old load_count/k_size_i and load_count%k_size_i
    // datapath. They are loaded once per tile and then increment by one, so the
    // RUN state address generation only sees counters and adders.
    logic [BANK_ADDR_W-1:0] act_row_r;
    logic [K_ADDR_W-1:0] act_k_r;
    logic [LANE_W-1:0] act_lane_r;
    logic [GB_ADDR_W-1:0] act_word_idx_r;
    logic [GB_ADDR_W-1:0] act_row_addr_r;

    logic [K_ADDR_W-1:0] wgt_k_r;
    logic [BANK_ADDR_W-1:0] wgt_col_r;
    logic [LANE_W-1:0] wgt_lane_r;
    logic [GB_ADDR_W-1:0] wgt_word_idx_r;
    logic [GB_ADDR_W-1:0] wgt_row_addr_r;

    logic gb_act_rd_valid_q;
    logic [GB_ADDR_W-1:0] gb_act_rd_addr_q;
    logic gb_wgt_rd_valid_q;
    logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_q;

    logic act_pending;
    logic act_pending_pad;
    logic [LANE_W-1:0] act_pending_lane;
    logic [BANK_ADDR_W-1:0] act_pending_bank;
    logic [K_ADDR_W-1:0] act_pending_idx;
    logic act_write_pending;
    logic act_write_pending_pad;
    logic [LANE_W-1:0] act_write_pending_lane;
    logic [BANK_ADDR_W-1:0] act_write_pending_bank;
    logic [K_ADDR_W-1:0] act_write_pending_idx;

    logic wgt_pending;
    logic wgt_pending_pad;
    logic [LANE_W-1:0] wgt_pending_lane;
    logic [BANK_ADDR_W-1:0] wgt_pending_bank;
    logic [K_ADDR_W-1:0] wgt_pending_idx;
    logic wgt_write_pending;
    logic wgt_write_pending_pad;
    logic [LANE_W-1:0] wgt_write_pending_lane;
    logic [BANK_ADDR_W-1:0] wgt_write_pending_bank;
    logic [K_ADDR_W-1:0] wgt_write_pending_idx;

    logic [DIM_W-1:0] global_row;
    logic [DIM_W-1:0] global_col;
    logic [GB_ADDR_W-1:0] k_word_tiles;
    logic [GB_ADDR_W-1:0] n_word_tiles;

    assign busy_o = (state == RUN);
    assign max_entries_w = (ROW > COL) ? LOAD_COUNT_W'(ROW) * LOAD_COUNT_W'(k_size_i) :
                                         LOAD_COUNT_W'(COL) * LOAD_COUNT_W'(k_size_i);
    assign k_word_tiles = (GB_ADDR_W'(k_size_i) + GB_ADDR_W'(GB_LANES - 1)) / GB_ADDR_W'(GB_LANES);
    assign n_word_tiles = (GB_ADDR_W'(n_size_i) + GB_ADDR_W'(GB_LANES - 1)) / GB_ADDR_W'(GB_LANES);
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
            act_row_r <= '0;
            act_k_r <= '0;
            act_lane_r <= '0;
            act_word_idx_r <= '0;
            act_row_addr_r <= '0;
            wgt_k_r <= '0;
            wgt_col_r <= '0;
            wgt_lane_r <= '0;
            wgt_word_idx_r <= '0;
            wgt_row_addr_r <= '0;
            done_o <= 1'b0;
            gb_act_rd_valid_q <= 1'b0;
            gb_act_rd_addr_q <= '0;
            gb_wgt_rd_valid_q <= 1'b0;
            gb_wgt_rd_addr_q <= '0;
            act_pending <= 1'b0;
            act_pending_pad <= 1'b0;
            act_pending_lane <= '0;
            act_pending_bank <= '0;
            act_pending_idx <= '0;
            act_write_pending <= 1'b0;
            act_write_pending_pad <= 1'b0;
            act_write_pending_lane <= '0;
            act_write_pending_bank <= '0;
            act_write_pending_idx <= '0;
            wgt_pending <= 1'b0;
            wgt_pending_pad <= 1'b0;
            wgt_pending_lane <= '0;
            wgt_pending_bank <= '0;
            wgt_pending_idx <= '0;
            wgt_write_pending <= 1'b0;
            wgt_write_pending_pad <= 1'b0;
            wgt_write_pending_lane <= '0;
            wgt_write_pending_bank <= '0;
            wgt_write_pending_idx <= '0;
            clear_write_outputs();
        end else begin
            done_o <= 1'b0;
            clear_write_outputs();

            case (state)
                IDLE: begin
                    load_count <= '0;
                    act_row_r <= '0;
                    act_k_r <= '0;
                    act_lane_r <= '0;
                    act_word_idx_r <= '0;
                    act_row_addr_r <= act_base_addr_i + (GB_ADDR_W'(row_base_i) * k_word_tiles);
                    wgt_k_r <= '0;
                    wgt_col_r <= '0;
                    wgt_lane_r <= col_base_i[LANE_W-1:0];
                    wgt_word_idx_r <= GB_ADDR_W'(col_base_i) / GB_ADDR_W'(GB_LANES);
                    wgt_row_addr_r <= wgt_base_addr_i;
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
                            wr_data_o[0] <= act_write_pending_pad ? '0 :
                                            gb_act_rd_data_i[act_write_pending_lane*DATA_W +: DATA_W];
                        end

                        if (wgt_write_pending) begin
                            wr_en_o[1]   <= 1'b1;
                            wr_bank_o[1] <= wgt_write_pending_bank;
                            wr_idx_o[1]  <= wgt_write_pending_idx;
                            wr_data_o[1] <= wgt_write_pending_pad ? '0 :
                                            gb_wgt_rd_data_i[wgt_write_pending_lane*DATA_W +: DATA_W];
                        end

                        act_write_pending <= act_pending;
                        act_write_pending_pad <= act_pending_pad;
                        act_write_pending_lane <= act_pending_lane;
                        act_write_pending_bank <= act_pending_bank;
                        act_write_pending_idx <= act_pending_idx;

                        wgt_write_pending <= wgt_pending;
                        wgt_write_pending_pad <= wgt_pending_pad;
                        wgt_write_pending_lane <= wgt_pending_lane;
                        wgt_write_pending_bank <= wgt_pending_bank;
                        wgt_write_pending_idx <= wgt_pending_idx;

                        act_pending <= 1'b0;
                        wgt_pending <= 1'b0;

                        if (load_count < max_entries_w) begin
                            if (load_count < LOAD_COUNT_W'(ROW) * LOAD_COUNT_W'(k_size_i)) begin
                                global_row = row_base_i + DIM_W'(act_row_r);

                                act_pending <= 1'b1;
                                act_pending_pad <= (global_row >= m_size_i);
                                act_pending_lane <= act_lane_r;
                                act_pending_bank <= act_row_r;
                                act_pending_idx <= act_k_r;
                                gb_act_rd_valid_q <= (global_row < m_size_i);
                                gb_act_rd_addr_q <= act_row_addr_r + act_word_idx_r;

                                if ({1'b0, act_k_r} + K_COUNT_W'(1) >= k_size_i) begin
                                    act_k_r <= '0;
                                    act_lane_r <= '0;
                                    act_word_idx_r <= '0;
                                    act_row_r <= act_row_r + BANK_ADDR_W'(1);
                                    act_row_addr_r <= act_row_addr_r + k_word_tiles;
                                end else begin
                                    act_k_r <= act_k_r + K_ADDR_W'(1);
                                    if (act_lane_r == LANE_W'(GB_LANES - 1)) begin
                                        act_lane_r <= '0;
                                        act_word_idx_r <= act_word_idx_r + GB_ADDR_W'(1);
                                    end else begin
                                        act_lane_r <= act_lane_r + LANE_W'(1);
                                    end
                                end
                            end

                            if (load_count < LOAD_COUNT_W'(COL) * LOAD_COUNT_W'(k_size_i)) begin
                                global_col = col_base_i + DIM_W'(wgt_col_r);

                                wgt_pending <= 1'b1;
                                wgt_pending_pad <= (global_col >= n_size_i);
                                wgt_pending_lane <= wgt_lane_r;
                                wgt_pending_bank <= wgt_col_r;
                                wgt_pending_idx <= wgt_k_r;
                                gb_wgt_rd_valid_q <= (global_col < n_size_i);
                                gb_wgt_rd_addr_q <= wgt_row_addr_r + wgt_word_idx_r;

                                if (wgt_col_r == BANK_ADDR_W'(COL - 1)) begin
                                    wgt_col_r <= '0;
                                    wgt_lane_r <= col_base_i[LANE_W-1:0];
                                    wgt_word_idx_r <= GB_ADDR_W'(col_base_i) / GB_ADDR_W'(GB_LANES);
                                    wgt_k_r <= wgt_k_r + K_ADDR_W'(1);
                                    wgt_row_addr_r <= wgt_row_addr_r + n_word_tiles;
                                end else begin
                                    wgt_col_r <= wgt_col_r + BANK_ADDR_W'(1);
                                    if (wgt_lane_r == LANE_W'(GB_LANES - 1)) begin
                                        wgt_lane_r <= '0;
                                        wgt_word_idx_r <= wgt_word_idx_r + GB_ADDR_W'(1);
                                    end else begin
                                        wgt_lane_r <= wgt_lane_r + LANE_W'(1);
                                    end
                                end
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
