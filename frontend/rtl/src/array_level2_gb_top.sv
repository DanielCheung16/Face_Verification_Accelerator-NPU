/*
 * Global-buffer-facing level-2 array top.
 *
 * External flow:
 *   1. Program m/k/n size and tile bases.
 *   2. Pulse preload_start_i to move one tile from global buffers into local
 *      banked buffers.
 *   3. Wait for preload_done_o.
 *   4. Pulse compute_start_i to run the systolic array on the preloaded tile.
 */
module array_level2_gb_top #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int K_MAX     = 512,
    parameter int COUNT_W   = 16,
    parameter int K_ADDR_W  = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int BUF_NUM   = 2,
    parameter int DIM_W     = 16,
    parameter int GB_ADDR_W = 32,

    localparam int MAX_RC = (ROW > COL) ? ROW : COL,
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC)
) (
    input logic clk,
    input logic rst_n,
    input logic run_en_i,

    input logic preload_start_i,
    output logic preload_busy_o,
    output logic preload_done_o,

    input logic compute_start_i,
    output logic compute_done_o,

    input logic [K_ADDR_W:0] k_size_i,
    input logic [DIM_W-1:0]  m_size_i,
    input logic [DIM_W-1:0]  n_size_i,
    input logic [DIM_W-1:0]  row_base_i,
    input logic [DIM_W-1:0]  col_base_i,

    output logic                 gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic signed [DATA_W-1:0] gb_act_rd_data_i,

    output logic                 gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic signed [DATA_W-1:0] gb_wgt_rd_data_i,

    output logic                    valid_o [ROW][COL],
    output logic signed [ACC_W-1:0] mac_o   [ROW][COL]
);

    logic                     preload_wr_en   [BUF_NUM];
    logic [BANK_ADDR_W-1:0]   preload_wr_bank [BUF_NUM];
    logic [K_ADDR_W-1:0]      preload_wr_idx  [BUF_NUM];
    logic signed [DATA_W-1:0] preload_wr_data [BUF_NUM];

    gemm_preload #(
        .ROW       (ROW),
        .COL       (COL),
        .K_MAX     (K_MAX),
        .DATA_W    (DATA_W),
        .GB_DATA_W (DATA_W),
        .DIM_W     (DIM_W),
        .GB_ADDR_W (GB_ADDR_W),
        .BUF_NUM   (BUF_NUM),
        .K_ADDR_W  (K_ADDR_W)
    ) u_preload (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_i            (preload_start_i),
        .run_en_i           (run_en_i),
        .busy_o             (preload_busy_o),
        .done_o             (preload_done_o),
        .m_size_i           (m_size_i),
        .k_size_i           (k_size_i),
        .n_size_i           (n_size_i),
        .row_base_i         (row_base_i),
        .col_base_i         (col_base_i),
        .act_base_addr_i    ('0),
        .wgt_base_addr_i    ('0),
        .gb_act_rd_valid_o  (gb_act_rd_valid_o),
        .gb_act_rd_addr_o   (gb_act_rd_addr_o),
        .gb_act_rd_data_i   (gb_act_rd_data_i),
        .gb_wgt_rd_valid_o  (gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o   (gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i   (gb_wgt_rd_data_i),
        .wr_en_o            (preload_wr_en),
        .wr_bank_o          (preload_wr_bank),
        .wr_idx_o           (preload_wr_idx),
        .wr_data_o          (preload_wr_data)
    );

    array_level2_top #(
        .ROW      (ROW),
        .COL      (COL),
        .K_MAX    (K_MAX),
        .COUNT_W  (COUNT_W),
        .K_ADDR_W (K_ADDR_W),
        .DATA_W   (DATA_W),
        .ACC_W    (ACC_W),
        .BUF_NUM  (BUF_NUM)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .run_en_i   (run_en_i),
        .wr_en_i    (preload_wr_en),
        .wr_bank_i  (preload_wr_bank),
        .wr_idx_i   (preload_wr_idx),
        .wr_data_i  (preload_wr_data),
        .k_size_i   (k_size_i),
        .start_i    (compute_start_i),
        .done_o     (compute_done_o),
        .valid_o    (valid_o),
        .mac_o      (mac_o)
    );

endmodule
