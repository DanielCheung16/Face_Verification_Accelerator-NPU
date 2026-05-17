module conv1x1_top #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int K_MAX     = 512,
    parameter int COUNT_W   = 16,
    parameter int K_ADDR_W  = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int BIAS_W    = 64,
    parameter int OUT_W     = 8,
    parameter int MULT_W    = 32,
    parameter int SHIFT_W   = 6,
    parameter int BUF_NUM   = 2,
    parameter int DIM_W     = 16,
    parameter int GB_DATA_W = 128,
    parameter int AO_DEPTH  = 8192,
    parameter int WGT_DEPTH = 8192,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int PARAM_ADDR_W = 16,
    parameter int LAYER_IDX_W = 4,

    localparam int AO_MASK_W = GB_DATA_W / DATA_W,
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    input  logic start_i,
    input  logic [LAYER_IDX_W-1:0] layer_idx_i,
    output logic busy_o,
    output logic done_o,

    input  logic [K_ADDR_W:0] k_size_i,
    input  logic [DIM_W-1:0]  m_size_i,
    input  logic [DIM_W-1:0]  n_size_i,
    input  logic [GB_ADDR_W-1:0] act_base_addr_i,
    input  logic [GB_ADDR_W-1:0] wgt_base_addr_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic                 residual_en_i,
    input  logic [GB_ADDR_W-1:0] residual_base_addr_i,

    input  logic [1:0] mode_i,
    input  logic signed [OUT_W-1:0] output_zero_point_i,
    input  logic [PARAM_ADDR_W-1:0] common_param_base_i,
    input  logic [PARAM_ADDR_W-1:0] prelu_param_base_i,
    input  logic [PARAM_ADDR_W-1:0] residual_param_base_i,
    input  logic signed [BIAS_W-1:0] bias_i       [COL],
    input  logic signed [MULT_W-1:0] multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       shift_i      [COL],
    input  logic signed [OUT_W-1:0]  zero_point_i [COL],
    input  logic signed [MULT_W-1:0] prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       prelu_shift_i      [COL],
    input  logic signed [MULT_W-1:0] residual_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]       residual_shift_i      [COL],
    input  logic signed [ACC_W-1:0]  residual_zero_point_i [COL],

    output logic                     gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_act_rd_data_i,

    output logic                     gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_wgt_rd_data_i,

    output logic                     gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]     gb_ao_wr_data_o,
    output logic [AO_MASK_W-1:0]     gb_ao_wr_mask_o,

    output logic                       quant_common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    quant_common_rd_addr_o,
    input  logic                       quant_common_rd_valid_i,
    output logic                       quant_prelu_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    quant_prelu_rd_addr_o,
    input  logic                       quant_prelu_rd_valid_i,
    output logic                       quant_residual_rd_en_o,
    output logic [PARAM_ADDR_W-1:0]    quant_residual_rd_addr_o,
    input  logic                       quant_residual_rd_valid_i,
    input  logic signed [BIAS_W-1:0]   quant_param_bias_i,
    input  logic signed [MULT_W-1:0]   quant_param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]         quant_param_requant_shift_i,
    input  logic signed [MULT_W-1:0]   quant_param_prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]         quant_param_prelu_shift_i,
    input  logic signed [MULT_W-1:0]   quant_param_residual_multiplier_i,
    input  logic [SHIFT_W-1:0]         quant_param_residual_shift_i,
    input  logic signed [BIAS_W-1:0]   quant_param_residual_zero_point_i
);
    logic                       post_valid_tile;
    logic                       post_done_tile;
    logic [DIM_W-1:0]           post_row_base;
    logic [DIM_W-1:0]           post_col_base;
    logic [DIM_W-1:0]           post_m_size;
    logic [DIM_W-1:0]           post_n_size;
    logic [1:0]                 post_mode;
    logic                       post_valid [ROW][COL];
    logic signed [ACC_W-1:0]    post_acc [ROW][COL];
    logic signed [ACC_W-1:0]    post_residual [ROW][COL];
    logic signed [BIAS_W-1:0]   post_bias [COL];
    logic signed [MULT_W-1:0]   post_multiplier [COL];
    logic [SHIFT_W-1:0]         post_shift [COL];
    logic signed [OUT_W-1:0]    post_zero_point [COL];
    logic signed [MULT_W-1:0]   post_prelu_multiplier [COL];
    logic [SHIFT_W-1:0]         post_prelu_shift [COL];
    logic signed [MULT_W-1:0]   post_residual_multiplier [COL];
    logic [SHIFT_W-1:0]         post_residual_shift [COL];
    logic signed [ACC_W-1:0]    post_residual_zero_point [COL];
    logic                       wb_capture_en;
    logic                       wb_done;
    logic [DIM_W-1:0]           wb_m_size;
    logic [DIM_W-1:0]           wb_n_size;
    logic [GB_ADDR_W-1:0]       wb_out_base_addr;

    // Compute/topology block: preload activations/weights and produce one
    // INT32 output tile plus tile metadata for the conv1x1 writeback path.
    conv1x1_level3_top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .COUNT_W(COUNT_W),
        .K_ADDR_W(K_ADDR_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .BUF_NUM(BUF_NUM),
        .DIM_W(DIM_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .AO_ADDR_W(AO_ADDR_W),
        .WGT_ADDR_W(WGT_ADDR_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .LAYER_IDX_W(LAYER_IDX_W)
    ) u_compute (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .layer_idx_i(layer_idx_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .k_size_i(k_size_i),
        .m_size_i(m_size_i),
        .n_size_i(n_size_i),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .out_base_addr_i(out_base_addr_i),
        .residual_en_i(residual_en_i),
        .residual_base_addr_i(residual_base_addr_i),
        .mode_i(mode_i),
        .output_zero_point_i(output_zero_point_i),
        .common_param_base_i(common_param_base_i),
        .prelu_param_base_i(prelu_param_base_i),
        .residual_param_base_i(residual_param_base_i),
        .bias_i(bias_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .zero_point_i(zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .post_valid_tile_o(post_valid_tile),
        .post_valid_tile_i(post_done_tile),
        .post_row_base_o(post_row_base),
        .post_col_base_o(post_col_base),
        .post_m_size_o(post_m_size),
        .post_n_size_o(post_n_size),
        .post_mode_o(post_mode),
        .post_valid_o(post_valid),
        .post_acc_o(post_acc),
        .post_residual_o(post_residual),
        .post_bias_o(post_bias),
        .post_multiplier_o(post_multiplier),
        .post_shift_o(post_shift),
        .post_zero_point_o(post_zero_point),
        .post_prelu_multiplier_o(post_prelu_multiplier),
        .post_prelu_shift_o(post_prelu_shift),
        .post_residual_multiplier_o(post_residual_multiplier),
        .post_residual_shift_o(post_residual_shift),
        .post_residual_zero_point_o(post_residual_zero_point),
        .wb_capture_en_o(wb_capture_en),
        .wb_done_i(wb_done),
        .wb_m_size_o(wb_m_size),
        .wb_n_size_o(wb_n_size),
        .wb_out_base_addr_o(wb_out_base_addr),
        .gb_act_rd_valid_o(gb_act_rd_valid_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_valid_o(gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .quant_common_rd_en_o(quant_common_rd_en_o),
        .quant_common_rd_addr_o(quant_common_rd_addr_o),
        .quant_common_rd_valid_i(quant_common_rd_valid_i),
        .quant_prelu_rd_en_o(quant_prelu_rd_en_o),
        .quant_prelu_rd_addr_o(quant_prelu_rd_addr_o),
        .quant_prelu_rd_valid_i(quant_prelu_rd_valid_i),
        .quant_residual_rd_en_o(quant_residual_rd_en_o),
        .quant_residual_rd_addr_o(quant_residual_rd_addr_o),
        .quant_residual_rd_valid_i(quant_residual_rd_valid_i),
        .quant_param_bias_i(quant_param_bias_i),
        .quant_param_requant_multiplier_i(quant_param_requant_multiplier_i),
        .quant_param_requant_shift_i(quant_param_requant_shift_i),
        .quant_param_prelu_multiplier_i(quant_param_prelu_multiplier_i),
        .quant_param_prelu_shift_i(quant_param_prelu_shift_i),
        .quant_param_residual_multiplier_i(quant_param_residual_multiplier_i),
        .quant_param_residual_shift_i(quant_param_residual_shift_i),
        .quant_param_residual_zero_point_i(quant_param_residual_zero_point_i)
    );

    // Conv1x1-specific writeback path. It keeps the tile-wide postprocess and
    // row-packed NHWC writeback logic together, mirroring spatial_wb.
    conv1x1_wb #(
        .ROW(ROW),
        .COL(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_wb (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_tile_i(post_valid_tile),
        .valid_tile_o(post_done_tile),
        .row_base_i(post_row_base),
        .col_base_i(post_col_base),
        .m_size_i(post_m_size),
        .n_size_i(post_n_size),
        .mode_i(post_mode),
        .valid_i(post_valid),
        .acc_i(post_acc),
        .residual_i(post_residual),
        .bias_i(post_bias),
        .multiplier_i(post_multiplier),
        .shift_i(post_shift),
        .zero_point_i(post_zero_point),
        .prelu_multiplier_i(post_prelu_multiplier),
        .prelu_shift_i(post_prelu_shift),
        .residual_multiplier_i(post_residual_multiplier),
        .residual_shift_i(post_residual_shift),
        .residual_zero_point_i(post_residual_zero_point),
        .wb_capture_en_i(wb_capture_en),
        .wb_done_o(wb_done),
        .wb_m_size_i(wb_m_size),
        .wb_n_size_i(wb_n_size),
        .wb_out_base_addr_i(wb_out_base_addr),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o)
    );

endmodule
