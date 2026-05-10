module conv1x1_gb_top #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int K_MAX     = 512,
    parameter int COUNT_W   = 16,
    parameter int K_ADDR_W  = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int OUT_W     = 8,
    parameter int MULT_W    = 32,
    parameter int SHIFT_W   = 6,
    parameter int BUF_NUM   = 2,
    parameter int DIM_W     = 16,
    parameter int GB_ADDR_W = 32
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

    input logic [1:0] mode_i,
    input logic signed [ACC_W-1:0]  bias_i       [COL],
    input logic signed [MULT_W-1:0] multiplier_i [COL],
    input logic [SHIFT_W-1:0]       shift_i      [COL],
    input logic signed [OUT_W-1:0]  zero_point_i [COL],
    input logic signed [MULT_W-1:0] prelu_multiplier_i [COL],
    input logic [SHIFT_W-1:0]       prelu_shift_i      [COL],
    input logic signed [ACC_W-1:0]  residual_i [ROW][COL],
    input logic signed [MULT_W-1:0] residual_multiplier_i [COL],
    input logic [SHIFT_W-1:0]       residual_shift_i      [COL],
    input logic signed [ACC_W-1:0]  residual_zero_point_i [COL],

    output logic                 gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic signed [DATA_W-1:0] gb_act_rd_data_i,

    output logic                 gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic signed [DATA_W-1:0] gb_wgt_rd_data_i,

    output logic                    valid_o [ROW][COL],
    output logic signed [OUT_W-1:0] data_o  [ROW][COL]
);
    logic                    mac_valid [ROW][COL];
    logic signed [ACC_W-1:0] mac_data  [ROW][COL];

    array_level2_gb_top #(
        .ROW       (ROW),
        .COL       (COL),
        .K_MAX     (K_MAX),
        .COUNT_W   (COUNT_W),
        .K_ADDR_W  (K_ADDR_W),
        .DATA_W    (DATA_W),
        .ACC_W     (ACC_W),
        .BUF_NUM   (BUF_NUM),
        .DIM_W     (DIM_W),
        .GB_ADDR_W (GB_ADDR_W)
    ) u_array_level2 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .run_en_i            (run_en_i),
        .preload_start_i     (preload_start_i),
        .preload_busy_o      (preload_busy_o),
        .preload_done_o      (preload_done_o),
        .compute_start_i     (compute_start_i),
        .compute_done_o      (compute_done_o),
        .k_size_i            (k_size_i),
        .m_size_i            (m_size_i),
        .n_size_i            (n_size_i),
        .row_base_i          (row_base_i),
        .col_base_i          (col_base_i),
        .gb_act_rd_valid_o   (gb_act_rd_valid_o),
        .gb_act_rd_addr_o    (gb_act_rd_addr_o),
        .gb_act_rd_data_i    (gb_act_rd_data_i),
        .gb_wgt_rd_valid_o   (gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o    (gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i    (gb_wgt_rd_data_i),
        .valid_o             (mac_valid),
        .mac_o               (mac_data)
    );

    conv1x1_output_postprocess #(
        .ROW     (ROW),
        .COL     (COL),
        .ACC_W   (ACC_W),
        .OUT_W   (OUT_W),
        .MULT_W  (MULT_W),
        .SHIFT_W (SHIFT_W),
        .DIM_W   (DIM_W)
    ) u_output_postprocess (
        .row_base_i   (row_base_i),
        .col_base_i   (col_base_i),
        .m_size_i     (m_size_i),
        .n_size_i     (n_size_i),
        .valid_i      (mac_valid),
        .acc_i        (mac_data),
        .mode_i       (mode_i),
        .bias_i       (bias_i),
        .multiplier_i (multiplier_i),
        .shift_i      (shift_i),
        .zero_point_i (zero_point_i),
        .prelu_multiplier_i (prelu_multiplier_i),
        .prelu_shift_i      (prelu_shift_i),
        .residual_i         (residual_i),
        .residual_multiplier_i (residual_multiplier_i),
        .residual_shift_i      (residual_shift_i),
        .residual_zero_point_i (residual_zero_point_i),
        .valid_o      (valid_o),
        .data_o       (data_o)
    );
endmodule
