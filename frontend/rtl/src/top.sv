module top #(
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
    parameter bit AO_TRUE_DUAL_PORT = 1'b0,
    parameter bit WGT_TRUE_DUAL_PORT = 1'b0,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int NUM_DEV = 1,
    parameter int MAX_LAYER = 8,
    parameter bit USE_INTERNAL_QUANT_PARAMS = 1'b0,

    localparam int AO_MASK_W = GB_DATA_W / DATA_W,
    localparam int WGT_MASK_W = GB_DATA_W / DATA_W,
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W,
    localparam int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW),
    localparam int FINAL_VEC = 128
) (
    input  logic                     aclk,
    input  logic                     aresetn,
    input  logic                     sys_start,

    output logic                     sys_done,
    output logic                     final_valid_o,
    output logic [FINAL_VEC-1:0]     final_vec_o,

    // Host/DMA access to activation/output SRAM. The host should use this port
    // only when the accelerator is idle.
    input  logic                     host_ao_rd_en_i,
    input  logic                     host_ao_wr_en_i,
    input  logic [AO_ADDR_W-1:0]     host_ao_addr_i,
    input  logic [GB_DATA_W-1:0]     host_ao_wr_data_i,
    input  logic [AO_MASK_W-1:0]     host_ao_wr_mask_i,
    output logic [GB_DATA_W-1:0]     host_ao_rd_data_o,

    // Host/DMA access to weight SRAM. With WGT_TRUE_DUAL_PORT=0 this port is
    // intended for weight loading; host_wgt_rd_data_o is tied off by the SRAM
    // wrapper. Set WGT_TRUE_DUAL_PORT=1 when host readback is required.
    input  logic                     host_wgt_en_i,
    input  logic                     host_wgt_wr_en_i,
    input  logic [WGT_ADDR_W-1:0]    host_wgt_addr_i,
    input  logic [GB_DATA_W-1:0]     host_wgt_wr_data_i,
    input  logic [WGT_MASK_W-1:0]    host_wgt_wr_mask_i,
    output logic [GB_DATA_W-1:0]     host_wgt_rd_data_o
);
    localparam int CONV1X1_DEV = 0;

    logic accelerator_active_w;

    logic dev_start [NUM_DEV];
    logic dev_busy  [NUM_DEV];
    logic dev_done  [NUM_DEV];

    logic [K_ADDR_W:0]     k_size;
    logic [DIM_W-1:0]      m_size;
    logic [DIM_W-1:0]      n_size;
    logic [GB_ADDR_W-1:0]  act_base_addr;
    logic [GB_ADDR_W-1:0]  wgt_base_addr;
    logic [GB_ADDR_W-1:0]  out_base_addr;
    logic                  residual_en;
    logic [GB_ADDR_W-1:0]  residual_base_addr;
    logic [MAX_LAYER-1:0]  layer_idx;

    logic [1:0]                    mode;
    logic signed [BIAS_W-1:0]      bias [COL];
    logic signed [MULT_W-1:0]      multiplier [COL];
    logic [SHIFT_W-1:0]            shift [COL];
    logic signed [OUT_W-1:0]       zero_point [COL];
    logic signed [MULT_W-1:0]      prelu_multiplier [COL];
    logic [SHIFT_W-1:0]            prelu_shift [COL];
    logic signed [MULT_W-1:0]      residual_multiplier [COL];
    logic [SHIFT_W-1:0]            residual_shift [COL];
    logic signed [ACC_W-1:0]       residual_zero_point [COL];

    logic                       conv_post_valid_tile;
    logic                       post_valid_tile;
    logic [DIM_W-1:0]           conv_post_row_base;
    logic [DIM_W-1:0]           conv_post_col_base;
    logic [DIM_W-1:0]           conv_post_m_size;
    logic [DIM_W-1:0]           conv_post_n_size;
    logic [1:0]                 conv_post_mode;
    logic                       conv_post_valid [ROW][COL];
    logic signed [ACC_W-1:0]    conv_post_acc [ROW][COL];
    logic signed [ACC_W-1:0]    conv_post_residual [ROW][COL];
    logic signed [BIAS_W-1:0]   conv_post_bias [COL];
    logic signed [MULT_W-1:0]   conv_post_multiplier [COL];
    logic [SHIFT_W-1:0]         conv_post_shift [COL];
    logic signed [OUT_W-1:0]    conv_post_zero_point [COL];
    logic signed [MULT_W-1:0]   conv_post_prelu_multiplier [COL];
    logic [SHIFT_W-1:0]         conv_post_prelu_shift [COL];
    logic signed [MULT_W-1:0]   conv_post_residual_multiplier [COL];
    logic [SHIFT_W-1:0]         conv_post_residual_shift [COL];
    logic signed [ACC_W-1:0]    conv_post_residual_zero_point [COL];
    logic                       conv_wb_capture_en;
    logic                       conv_wb_done;
    logic [DIM_W-1:0]           conv_wb_m_size;
    logic [DIM_W-1:0]           conv_wb_n_size;
    logic [GB_ADDR_W-1:0]       conv_wb_out_base_addr;

    logic                       post_valid [ROW][COL];
    logic signed [OUT_W-1:0]    post_data [ROW][COL];
    logic [WB_ADDR_W-1:0]       conv_wb_rd_addr;
    logic [GB_DATA_W-1:0]       conv_wb_data;

    logic                     dev_act_rd_valid [NUM_DEV];
    logic [GB_ADDR_W-1:0]     dev_act_rd_addr  [NUM_DEV];
    logic [GB_DATA_W-1:0]     dev_act_rd_data  [NUM_DEV];
    logic                     dev_ao_wr_valid  [NUM_DEV];
    logic [GB_ADDR_W-1:0]     dev_ao_wr_addr   [NUM_DEV];
    logic [GB_DATA_W-1:0]     dev_ao_wr_data   [NUM_DEV];
    logic [AO_MASK_W-1:0]     dev_ao_wr_mask   [NUM_DEV];
    logic                     dev_wgt_rd_valid [NUM_DEV];
    logic [GB_ADDR_W-1:0]     dev_wgt_rd_addr  [NUM_DEV];
    logic [GB_DATA_W-1:0]     dev_wgt_rd_data  [NUM_DEV];

    logic                     sw_act_rd_valid;
    logic [GB_ADDR_W-1:0]     sw_act_rd_addr;
    logic [GB_DATA_W-1:0]     sw_act_rd_data;
    logic                     sw_ao_wr_valid;
    logic [GB_ADDR_W-1:0]     sw_ao_wr_addr;
    logic [GB_DATA_W-1:0]     sw_ao_wr_data;
    logic [AO_MASK_W-1:0]     sw_ao_wr_mask;
    logic                     sw_wgt_rd_valid;
    logic [GB_ADDR_W-1:0]     sw_wgt_rd_addr;
    logic [GB_DATA_W-1:0]     sw_wgt_rd_data;

    logic                     ao_rd_en;
    logic [AO_ADDR_W-1:0]     ao_rd_addr;
    logic [GB_DATA_W-1:0]     ao_rd_data;
    logic                     ao_wr_en;
    logic [AO_ADDR_W-1:0]     ao_wr_addr;
    logic [GB_DATA_W-1:0]     ao_wr_data;
    logic [AO_MASK_W-1:0]     ao_wr_mask;

    assign accelerator_active_w = sys_start && !sys_done;

    assign ao_rd_en   = accelerator_active_w ? sw_act_rd_valid : host_ao_rd_en_i;
    assign ao_rd_addr = accelerator_active_w ? sw_act_rd_addr[AO_ADDR_W-1:0] : host_ao_addr_i;
    assign sw_act_rd_data = ao_rd_data;
    assign host_ao_rd_data_o = ao_rd_data;

    assign ao_wr_en   = accelerator_active_w ? sw_ao_wr_valid : host_ao_wr_en_i;
    assign ao_wr_addr = accelerator_active_w ? sw_ao_wr_addr[AO_ADDR_W-1:0] : host_ao_addr_i;
    assign ao_wr_data = accelerator_active_w ? sw_ao_wr_data : host_ao_wr_data_i;
    assign ao_wr_mask = accelerator_active_w ? sw_ao_wr_mask : host_ao_wr_mask_i;

    activation_output_global_buffer #(
        .DATA_W(GB_DATA_W),
        .DEPTH(AO_DEPTH),
        .BYTE_W(DATA_W),
        .TRUE_DUAL_PORT(AO_TRUE_DUAL_PORT),
        .ADDR_W(AO_ADDR_W)
    ) u_ao_gb (
        .clk(aclk),
        .rst_n(aresetn),
        .rd_en_i(ao_rd_en),
        .rd_addr_i(ao_rd_addr),
        .rd_data_o(ao_rd_data),
        .wr_en_i(ao_wr_en),
        .wr_addr_i(ao_wr_addr),
        .wr_data_i(ao_wr_data),
        .wr_mask_i(ao_wr_mask),
        .aux_en_i(1'b0),
        .aux_wr_en_i(1'b0),
        .aux_addr_i('0),
        .aux_wr_data_i('0),
        .aux_wr_mask_i('0),
        .aux_rd_data_o()
    );

    weight_global_buffer #(
        .DATA_W(GB_DATA_W),
        .DEPTH(WGT_DEPTH),
        .BYTE_W(DATA_W),
        .TRUE_DUAL_PORT(WGT_TRUE_DUAL_PORT),
        .ADDR_W(WGT_ADDR_W)
    ) u_wgt_gb (
        .clk(aclk),
        .rst_n(aresetn),
        .load_en_i(host_wgt_en_i && !accelerator_active_w),
        .load_wr_en_i(host_wgt_wr_en_i && !accelerator_active_w),
        .load_addr_i(host_wgt_addr_i),
        .load_wr_data_i(host_wgt_wr_data_i),
        .load_wr_mask_i(host_wgt_wr_mask_i),
        .load_rd_data_o(host_wgt_rd_data_o),
        .acc_rd_en_i(sw_wgt_rd_valid),
        .acc_rd_addr_i(sw_wgt_rd_addr[WGT_ADDR_W-1:0]),
        .acc_rd_data_o(sw_wgt_rd_data)
    );

    layer_switcher #(
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
        .NUM_DEV(NUM_DEV),
        .MAX_LAYER(MAX_LAYER)
    ) u_layer_switcher (
        .clk(aclk),
        .rst_n(aresetn),
        .sys_start(sys_start),
        .sys_done(sys_done),
        .start_o(dev_start),
        .busy_i(dev_busy),
        .done_i(dev_done),
        .k_size_o(k_size),
        .m_size_o(m_size),
        .n_size_o(n_size),
        .act_base_addr_o(act_base_addr),
        .wgt_base_addr_o(wgt_base_addr),
        .out_base_addr_o(out_base_addr),
        .residual_en_o(residual_en),
        .residual_base_addr_o(residual_base_addr),
        .layer_idx_o(layer_idx),
        .mode_o(mode),
        .bias_o(bias),
        .multiplier_o(multiplier),
        .shift_o(shift),
        .zero_point_o(zero_point),
        .prelu_multiplier_o(prelu_multiplier),
        .prelu_shift_o(prelu_shift),
        .residual_multiplier_o(residual_multiplier),
        .residual_shift_o(residual_shift),
        .residual_zero_point_o(residual_zero_point),
        .dev_act_rd_valid_i(dev_act_rd_valid),
        .dev_act_rd_addr_i(dev_act_rd_addr),
        .dev_act_rd_data_o(dev_act_rd_data),
        .dev_ao_wr_valid_i(dev_ao_wr_valid),
        .dev_ao_wr_addr_i(dev_ao_wr_addr),
        .dev_ao_wr_data_i(dev_ao_wr_data),
        .dev_ao_wr_mask_i(dev_ao_wr_mask),
        .dev_wgt_rd_valid_i(dev_wgt_rd_valid),
        .dev_wgt_rd_addr_i(dev_wgt_rd_addr),
        .dev_wgt_rd_data_o(dev_wgt_rd_data),
        .gb_act_rd_valid_o(sw_act_rd_valid),
        .gb_act_rd_addr_o(sw_act_rd_addr),
        .gb_act_rd_data_i(sw_act_rd_data),
        .gb_ao_wr_valid_o(sw_ao_wr_valid),
        .gb_ao_wr_addr_o(sw_ao_wr_addr),
        .gb_ao_wr_data_o(sw_ao_wr_data),
        .gb_ao_wr_mask_o(sw_ao_wr_mask),
        .gb_wgt_rd_valid_o(sw_wgt_rd_valid),
        .gb_wgt_rd_addr_o(sw_wgt_rd_addr),
        .gb_wgt_rd_data_i(sw_wgt_rd_data),
        .final_valid_o(final_valid_o),
        .final_vec_o(final_vec_o)
    );

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
        .USE_INTERNAL_QUANT_PARAMS(USE_INTERNAL_QUANT_PARAMS),
        .LAYER_IDX_W(MAX_LAYER)
    ) u_conv1x1_dev (
        .clk(aclk),
        .rst_n(aresetn),
        .run_en_i(1'b1),
        .start_i(dev_start[CONV1X1_DEV]),
        .layer_idx_i(layer_idx),
        .busy_o(dev_busy[CONV1X1_DEV]),
        .done_o(dev_done[CONV1X1_DEV]),
        .k_size_i(k_size),
        .m_size_i(m_size),
        .n_size_i(n_size),
        .act_base_addr_i(act_base_addr),
        .wgt_base_addr_i(wgt_base_addr),
        .out_base_addr_i(out_base_addr),
        .residual_en_i(residual_en),
        .residual_base_addr_i(residual_base_addr),
        .mode_i(mode),
        .bias_i(bias),
        .multiplier_i(multiplier),
        .shift_i(shift),
        .zero_point_i(zero_point),
        .prelu_multiplier_i(prelu_multiplier),
        .prelu_shift_i(prelu_shift),
        .residual_multiplier_i(residual_multiplier),
        .residual_shift_i(residual_shift),
        .residual_zero_point_i(residual_zero_point),
        .post_valid_tile_o(conv_post_valid_tile),
        .post_valid_tile_i(post_valid_tile),
        .post_row_base_o(conv_post_row_base),
        .post_col_base_o(conv_post_col_base),
        .post_m_size_o(conv_post_m_size),
        .post_n_size_o(conv_post_n_size),
        .post_mode_o(conv_post_mode),
        .post_valid_o(conv_post_valid),
        .post_acc_o(conv_post_acc),
        .post_residual_o(conv_post_residual),
        .post_bias_o(conv_post_bias),
        .post_multiplier_o(conv_post_multiplier),
        .post_shift_o(conv_post_shift),
        .post_zero_point_o(conv_post_zero_point),
        .post_prelu_multiplier_o(conv_post_prelu_multiplier),
        .post_prelu_shift_o(conv_post_prelu_shift),
        .post_residual_multiplier_o(conv_post_residual_multiplier),
        .post_residual_shift_o(conv_post_residual_shift),
        .post_residual_zero_point_o(conv_post_residual_zero_point),
        .wb_capture_en_o(conv_wb_capture_en),
        .wb_done_i(conv_wb_done),
        .wb_m_size_o(conv_wb_m_size),
        .wb_n_size_o(conv_wb_n_size),
        .wb_out_base_addr_o(conv_wb_out_base_addr),
        .gb_act_rd_valid_o(dev_act_rd_valid[CONV1X1_DEV]),
        .gb_act_rd_addr_o(dev_act_rd_addr[CONV1X1_DEV]),
        .gb_act_rd_data_i(dev_act_rd_data[CONV1X1_DEV]),
        .gb_wgt_rd_valid_o(dev_wgt_rd_valid[CONV1X1_DEV]),
        .gb_wgt_rd_addr_o(dev_wgt_rd_addr[CONV1X1_DEV]),
        .gb_wgt_rd_data_i(dev_wgt_rd_data[CONV1X1_DEV])
    );

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
        .clk(aclk),
        .rst_n(aresetn),
        .run_en_i(1'b1),
        .valid_tile_i(conv_post_valid_tile),
        .row_base_i(conv_post_row_base),
        .col_base_i(conv_post_col_base),
        .m_size_i(conv_post_m_size),
        .n_size_i(conv_post_n_size),
        .valid_i(conv_post_valid),
        .acc_i(conv_post_acc),
        .mode_i(conv_post_mode),
        .bias_i(conv_post_bias),
        .multiplier_i(conv_post_multiplier),
        .shift_i(conv_post_shift),
        .zero_point_i(conv_post_zero_point),
        .prelu_multiplier_i(conv_post_prelu_multiplier),
        .prelu_shift_i(conv_post_prelu_shift),
        .residual_i(conv_post_residual),
        .residual_multiplier_i(conv_post_residual_multiplier),
        .residual_shift_i(conv_post_residual_shift),
        .residual_zero_point_i(conv_post_residual_zero_point),
        .valid_o(post_valid),
        .valid_tile_o(post_valid_tile),
        .data_o(post_data)
    );

    wb_buffer #(
        .ROW(ROW),
        .COL(COL),
        .DATA_IN_W(OUT_W),
        .DATA_OUT_W(GB_DATA_W)
    ) u_wb_buffer (
        .aclk(aclk),
        .aresetn(aresetn),
        .wr_en_i(conv_wb_capture_en),
        .data_i(post_data),
        .rd_addr_i(conv_wb_rd_addr),
        .data_o(conv_wb_data)
    );

    wr_controller #(
        .ROW(ROW),
        .COL(COL),
        .DATA_OUT_W(GB_DATA_W),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_wr_controller (
        .aclk(aclk),
        .aresetn(aresetn),
        .n_size_i(conv_wb_n_size),
        .m_size_i(conv_wb_m_size),
        .out_base_addr_i(conv_wb_out_base_addr),
        .tile_process_done(conv_wb_capture_en),
        .data_i(conv_wb_data),
        .rd_addr_o(conv_wb_rd_addr),
        .ao_addr_o(dev_ao_wr_addr[CONV1X1_DEV]),
        .ao_wr_en_o(dev_ao_wr_valid[CONV1X1_DEV]),
        .ao_data_o(dev_ao_wr_data[CONV1X1_DEV]),
        .busy_o(),
        .done_o(conv_wb_done)
    );

    assign dev_ao_wr_mask[CONV1X1_DEV] = {AO_MASK_W{1'b1}};

    generate
        if (NUM_DEV > 1) begin : GEN_UNUSED_DEVICES
            for (genvar d = 0; d < NUM_DEV; d++) begin : GEN_DEV_TIEOFF
                if (d != CONV1X1_DEV) begin : GEN_UNUSED
                    assign dev_busy[d] = 1'b0;
                    assign dev_done[d] = 1'b0;
                    assign dev_act_rd_valid[d] = 1'b0;
                    assign dev_act_rd_addr[d] = '0;
                    assign dev_ao_wr_valid[d] = 1'b0;
                    assign dev_ao_wr_addr[d] = '0;
                    assign dev_ao_wr_data[d] = '0;
                    assign dev_ao_wr_mask[d] = '0;
                    assign dev_wgt_rd_valid[d] = 1'b0;
                    assign dev_wgt_rd_addr[d] = '0;
                end
            end
        end
    endgenerate

endmodule
