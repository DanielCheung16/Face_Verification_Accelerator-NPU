module conv1x1_wb #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int ACC_W     = 32,
    parameter int BIAS_W    = 64,
    parameter int OUT_W     = 8,
    parameter int MULT_W    = 32,
    parameter int SHIFT_W   = 6,
    parameter int DIM_W     = 16,
    parameter int GB_DATA_W = 128,
    parameter int GB_ADDR_W = 16,

    localparam int AO_MASK_W = GB_DATA_W / OUT_W,
    localparam int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,

    // Tile stream from the conv1x1 compute block.
    input  logic                       valid_tile_i,
    output logic                       valid_tile_o,
    input  logic [DIM_W-1:0]           row_base_i,
    input  logic [DIM_W-1:0]           col_base_i,
    input  logic [DIM_W-1:0]           m_size_i,
    input  logic [DIM_W-1:0]           n_size_i,
    input  logic [1:0]                 mode_i,
    input  logic                       valid_i [ROW][COL],
    input  logic signed [ACC_W-1:0]    acc_i [ROW][COL],
    input  logic signed [ACC_W-1:0]    residual_i [ROW][COL],
    input  logic signed [BIAS_W-1:0]   bias_i [COL],
    input  logic signed [MULT_W-1:0]   multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         shift_i [COL],
    input  logic signed [OUT_W-1:0]    zero_point_i [COL],
    input  logic signed [MULT_W-1:0]   prelu_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         prelu_shift_i [COL],
    input  logic signed [MULT_W-1:0]   residual_multiplier_i [COL],
    input  logic [SHIFT_W-1:0]         residual_shift_i [COL],
    input  logic signed [ACC_W-1:0]    residual_zero_point_i [COL],

    // Writeback control from the conv1x1 inside controller.
    input  logic                       wb_capture_en_i,
    output logic                       wb_done_o,
    input  logic [DIM_W-1:0]           wb_m_size_i,
    input  logic [DIM_W-1:0]           wb_n_size_i,
    input  logic [GB_ADDR_W-1:0]       wb_out_base_addr_i,

    // Activation/output global buffer write port.
    output logic                       gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]       gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]       gb_ao_wr_data_o,
    output logic [AO_MASK_W-1:0]       gb_ao_wr_mask_o
);
    logic                       post_valid [ROW][COL];
    logic signed [OUT_W-1:0]    post_data [ROW][COL];
    logic [WB_ADDR_W-1:0]       wb_rd_addr;
    logic [GB_DATA_W-1:0]       wb_data;

    assign gb_ao_wr_mask_o = {AO_MASK_W{1'b1}};

    // Conv1x1 postprocess keeps the existing tile-wide interface. This wrapper
    // only moves the datapath boundary out of the system top.
    conv1x1_output_postprocess #(
        .ROW(ROW),
        .COL(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W)
    ) u_postprocess (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_tile_i(valid_tile_i),
        .row_base_i(row_base_i),
        .col_base_i(col_base_i),
        .m_size_i(m_size_i),
        .n_size_i(n_size_i),
        .valid_i(valid_i),
        .acc_i(acc_i),
        .mode_i(mode_i),
        .bias_i(bias_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .zero_point_i(zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .residual_i(residual_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .valid_o(post_valid),
        .valid_tile_o(valid_tile_o),
        .data_o(post_data)
    );

    wb_buffer #(
        .ROW(ROW),
        .COL(COL),
        .DATA_IN_W(OUT_W),
        .DATA_OUT_W(GB_DATA_W)
    ) u_wb_buffer (
        .aclk(clk),
        .aresetn(rst_n),
        .wr_en_i(wb_capture_en_i),
        .data_i(post_data),
        .rd_addr_i(wb_rd_addr),
        .data_o(wb_data)
    );

    wr_controller #(
        .ROW(ROW),
        .COL(COL),
        .DATA_OUT_W(GB_DATA_W),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_wr_controller (
        .aclk(clk),
        .aresetn(rst_n),
        .n_size_i(wb_n_size_i),
        .m_size_i(wb_m_size_i),
        .out_base_addr_i(wb_out_base_addr_i),
        .tile_process_done(wb_capture_en_i),
        .data_i(wb_data),
        .rd_addr_o(wb_rd_addr),
        .ao_addr_o(gb_ao_wr_addr_o),
        .ao_wr_en_o(gb_ao_wr_valid_o),
        .ao_data_o(gb_ao_wr_data_o),
        .busy_o(),
        .done_o(wb_done_o)
    );

endmodule
