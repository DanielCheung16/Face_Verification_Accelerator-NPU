module top #(
    parameter int ROW       = 4,
    parameter int COL       = 4,
    parameter int K_MAX     = 64,
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
    parameter int GB_DATA_W = 32,
    parameter int AO_DEPTH  = 512,
    parameter int WGT_DEPTH = 512,
    parameter bit AO_TRUE_DUAL_PORT = 1'b0,
    parameter bit WGT_TRUE_DUAL_PORT = 1'b0,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int NUM_DEV = 2,
    parameter int MAX_LAYER = 8,
    parameter int COMMON_PARAM_DEPTH = 9792,
    parameter int PRELU_PARAM_DEPTH = 7552,
    parameter int RESIDUAL_PARAM_DEPTH = 1280,
    parameter int LAYER_CONFIG_PROFILE = 0,
    parameter int PARAM_DEPTH = (COMMON_PARAM_DEPTH > PRELU_PARAM_DEPTH) ?
                                ((COMMON_PARAM_DEPTH > RESIDUAL_PARAM_DEPTH) ? COMMON_PARAM_DEPTH : RESIDUAL_PARAM_DEPTH) :
                                ((PRELU_PARAM_DEPTH > RESIDUAL_PARAM_DEPTH) ? PRELU_PARAM_DEPTH : RESIDUAL_PARAM_DEPTH),
    parameter int PARAM_ADDR_W = (PARAM_DEPTH <= 1) ? 1 : $clog2(PARAM_DEPTH),
    parameter int SPATIAL_ACT_DEPTH = 1,
    parameter int SPATIAL_WGT_DEPTH = 32,
    parameter string QUANT_BIAS_INIT_FILE = "",
    parameter string QUANT_REQUANT_MULT_INIT_FILE = "",
    parameter string QUANT_REQUANT_SHIFT_INIT_FILE = "",
    parameter string QUANT_PRELU_MULT_INIT_FILE = "",
    parameter string QUANT_PRELU_SHIFT_INIT_FILE = "",
    parameter string QUANT_RESIDUAL_MULT_INIT_FILE = "",
    parameter string QUANT_RESIDUAL_SHIFT_INIT_FILE = "",
    parameter string QUANT_RESIDUAL_ZERO_POINT_INIT_FILE = "",

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
    localparam int SPATIAL_DEV = 1;
    localparam int SPATIAL_ELEM_CNT_W = 32;
    localparam int SPATIAL_WGT_BYTE_DEPTH = (GB_DATA_W / DATA_W) * SPATIAL_WGT_DEPTH;
    localparam int SPATIAL_WGT_RD_ADDR_W = (SPATIAL_WGT_BYTE_DEPTH <= 1) ? 1 : $clog2(SPATIAL_WGT_BYTE_DEPTH);
    localparam int SPATIAL_FILTER_CNT_W = SPATIAL_WGT_RD_ADDR_W + 1;

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
    logic [2:0]                    ifmap_size_code;
    logic [1:0]                    num_filter_code;
    logic                          stride;
    logic                          pad;
    logic signed [OUT_W-1:0]       output_zero_point;
    logic [PARAM_ADDR_W-1:0]       bias_base;
    logic [PARAM_ADDR_W-1:0]       requant_mult_base;
    logic [PARAM_ADDR_W-1:0]       requant_shift_base;
    logic [PARAM_ADDR_W-1:0]       prelu_mult_base;
    logic [PARAM_ADDR_W-1:0]       prelu_shift_base;
    logic [PARAM_ADDR_W-1:0]       residual_mult_base;
    logic [PARAM_ADDR_W-1:0]       residual_shift_base;
    logic [PARAM_ADDR_W-1:0]       residual_zero_point_base;

    logic signed [BIAS_W-1:0]      bias [COL];
    logic signed [MULT_W-1:0]      multiplier [COL];
    logic [SHIFT_W-1:0]            shift [COL];
    logic signed [OUT_W-1:0]       zero_point [COL];
    logic signed [MULT_W-1:0]      prelu_multiplier [COL];
    logic [SHIFT_W-1:0]            prelu_shift [COL];
    logic signed [MULT_W-1:0]      residual_multiplier [COL];
    logic [SHIFT_W-1:0]            residual_shift [COL];
    logic signed [ACC_W-1:0]       residual_zero_point [COL];

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

    logic                     quant_common_rd_en;
    logic [PARAM_ADDR_W-1:0]  quant_common_rd_addr;
    logic                     quant_common_rd_valid;
    logic                     quant_prelu_rd_en;
    logic [PARAM_ADDR_W-1:0]  quant_prelu_rd_addr;
    logic                     quant_prelu_rd_valid;
    logic                     quant_residual_rd_en;
    logic [PARAM_ADDR_W-1:0]  quant_residual_rd_addr;
    logic                     quant_residual_rd_valid;
    logic signed [BIAS_W-1:0] quant_param_bias;
    logic signed [MULT_W-1:0] quant_param_requant_multiplier;
    logic [SHIFT_W-1:0]       quant_param_requant_shift;
    logic signed [MULT_W-1:0] quant_param_prelu_multiplier;
    logic [SHIFT_W-1:0]       quant_param_prelu_shift;
    logic signed [MULT_W-1:0] quant_param_residual_multiplier;
    logic [SHIFT_W-1:0]       quant_param_residual_shift;
    logic signed [BIAS_W-1:0] quant_param_residual_zero_point;

    logic                     conv_quant_common_rd_en;
    logic [PARAM_ADDR_W-1:0]  conv_quant_common_rd_addr;
    logic                     conv_quant_prelu_rd_en;
    logic [PARAM_ADDR_W-1:0]  conv_quant_prelu_rd_addr;
    logic                     conv_quant_residual_rd_en;
    logic [PARAM_ADDR_W-1:0]  conv_quant_residual_rd_addr;

    logic                     spatial_quant_common_rd_en;
    logic [PARAM_ADDR_W-1:0]  spatial_quant_common_rd_addr;
    logic                     spatial_quant_prelu_rd_en;
    logic [PARAM_ADDR_W-1:0]  spatial_quant_prelu_rd_addr;
    logic                     spatial_quant_residual_rd_en;
    logic [PARAM_ADDR_W-1:0]  spatial_quant_residual_rd_addr;
    logic                     conv_quant_active_w;
    logic                     spatial_quant_active_w;

    logic [SPATIAL_ELEM_CNT_W-1:0] spatial_output_elements;
    logic [SPATIAL_FILTER_CNT_W-1:0] spatial_current_num_filter;
    logic signed [ACC_W-1:0] spatial_residual_stub;
    logic signed [ACC_W-1:0] spatial_output_zero_point;

    logic                     ao_rd_en;
    logic [AO_ADDR_W-1:0]     ao_rd_addr;
    logic [GB_DATA_W-1:0]     ao_rd_data;
    logic                     ao_wr_en;
    logic [AO_ADDR_W-1:0]     ao_wr_addr;
    logic [GB_DATA_W-1:0]     ao_wr_data;
    logic [AO_MASK_W-1:0]     ao_wr_mask;

    assign accelerator_active_w = sys_start && !sys_done;
    assign spatial_output_elements = SPATIAL_ELEM_CNT_W'(m_size) * SPATIAL_ELEM_CNT_W'(n_size);
    assign spatial_current_num_filter = SPATIAL_FILTER_CNT_W'(n_size);
    assign spatial_residual_stub = '0;
    assign spatial_output_zero_point = ACC_W'($signed(output_zero_point));
    assign conv_quant_active_w = dev_start[CONV1X1_DEV] || dev_busy[CONV1X1_DEV];
    assign spatial_quant_active_w = dev_start[SPATIAL_DEV] || dev_busy[SPATIAL_DEV];

    // quant_param_mem is shared globally. The switcher only starts one device
    // at a time, so this decode gives the active device ownership of all banks.
    always_comb begin
        quant_common_rd_en = 1'b0;
        quant_common_rd_addr = '0;
        quant_prelu_rd_en = 1'b0;
        quant_prelu_rd_addr = '0;
        quant_residual_rd_en = 1'b0;
        quant_residual_rd_addr = '0;

        unique case (1'b1)
            conv_quant_active_w: begin
                quant_common_rd_en = conv_quant_common_rd_en;
                quant_common_rd_addr = conv_quant_common_rd_addr;
                quant_prelu_rd_en = conv_quant_prelu_rd_en;
                quant_prelu_rd_addr = conv_quant_prelu_rd_addr;
                quant_residual_rd_en = conv_quant_residual_rd_en;
                quant_residual_rd_addr = conv_quant_residual_rd_addr;
            end

            spatial_quant_active_w: begin
                quant_common_rd_en = spatial_quant_common_rd_en;
                quant_common_rd_addr = spatial_quant_common_rd_addr;
                quant_prelu_rd_en = spatial_quant_prelu_rd_en;
                quant_prelu_rd_addr = spatial_quant_prelu_rd_addr;
                quant_residual_rd_en = spatial_quant_residual_rd_en;
                quant_residual_rd_addr = spatial_quant_residual_rd_addr;
            end

            default: begin
                // No active layer owns quant_param_mem.
            end
        endcase
    end

`ifndef SYNTHESIS
    initial begin
        if (NUM_DEV < 2) begin
            $fatal(1, "top requires NUM_DEV >= 2 for conv1x1 and spatial device slots");
        end
    end
`endif

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

    // Global per-channel postprocess parameter memory. Layer tops schedule
    // channel reads using the base addresses from layer_switcher/layer_config_mem.
    quant_param_mem #(
        .COMMON_PARAM_DEPTH(COMMON_PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PRELU_PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(RESIDUAL_PARAM_DEPTH),
        .COMMON_PARAM_ADDR_W(PARAM_ADDR_W),
        .PRELU_PARAM_ADDR_W(PARAM_ADDR_W),
        .RESIDUAL_PARAM_ADDR_W(PARAM_ADDR_W),
        .BIAS_W(BIAS_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .BIAS_INIT_FILE(QUANT_BIAS_INIT_FILE),
        .REQUANT_MULT_INIT_FILE(QUANT_REQUANT_MULT_INIT_FILE),
        .REQUANT_SHIFT_INIT_FILE(QUANT_REQUANT_SHIFT_INIT_FILE),
        .PRELU_MULT_INIT_FILE(QUANT_PRELU_MULT_INIT_FILE),
        .PRELU_SHIFT_INIT_FILE(QUANT_PRELU_SHIFT_INIT_FILE),
        .RESIDUAL_MULT_INIT_FILE(QUANT_RESIDUAL_MULT_INIT_FILE),
        .RESIDUAL_SHIFT_INIT_FILE(QUANT_RESIDUAL_SHIFT_INIT_FILE),
        .RESIDUAL_ZERO_POINT_INIT_FILE(QUANT_RESIDUAL_ZERO_POINT_INIT_FILE)
    ) u_quant_param_mem (
        .clk(aclk),
        .rst_n(aresetn),
        .common_rd_en_i(quant_common_rd_en),
        .common_rd_addr_i(quant_common_rd_addr),
        .prelu_rd_en_i(quant_prelu_rd_en),
        .prelu_rd_addr_i(quant_prelu_rd_addr),
        .residual_rd_en_i(quant_residual_rd_en),
        .residual_rd_addr_i(quant_residual_rd_addr),
        .common_rd_valid_o(quant_common_rd_valid),
        .prelu_rd_valid_o(quant_prelu_rd_valid),
        .residual_rd_valid_o(quant_residual_rd_valid),
        .bias_o(quant_param_bias),
        .requant_multiplier_o(quant_param_requant_multiplier),
        .requant_shift_o(quant_param_requant_shift),
        .prelu_multiplier_o(quant_param_prelu_multiplier),
        .prelu_shift_o(quant_param_prelu_shift),
        .residual_multiplier_o(quant_param_residual_multiplier),
        .residual_shift_o(quant_param_residual_shift),
        .residual_zero_point_o(quant_param_residual_zero_point)
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
        .MAX_LAYER(MAX_LAYER),
        .LAYER_CONFIG_PROFILE(LAYER_CONFIG_PROFILE),
        .PARAM_ADDR_W(PARAM_ADDR_W)
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
        .ifmap_size_code_o(ifmap_size_code),
        .num_filter_code_o(num_filter_code),
        .stride_o(stride),
        .pad_o(pad),
        .output_zero_point_o(output_zero_point),
        .bias_base_o(bias_base),
        .requant_mult_base_o(requant_mult_base),
        .requant_shift_base_o(requant_shift_base),
        .prelu_mult_base_o(prelu_mult_base),
        .prelu_shift_base_o(prelu_shift_base),
        .residual_mult_base_o(residual_mult_base),
        .residual_shift_base_o(residual_shift_base),
        .residual_zero_point_base_o(residual_zero_point_base),
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

    // Legacy scalar parameter wires are kept only to avoid a broad interface
    // cleanup in this step. The formal conv1x1 path reads quant_param_mem
    // through conv1x1_param_scheduler.
    always_comb begin
        for (int c = 0; c < COL; c++) begin
            bias[c] = '0;
            multiplier[c] = MULT_W'(1);
            shift[c] = '0;
            zero_point[c] = '0;
            prelu_multiplier[c] = MULT_W'(1);
            prelu_shift[c] = '0;
            residual_multiplier[c] = MULT_W'(1);
            residual_shift[c] = '0;
            residual_zero_point[c] = '0;
        end
    end

    // Conv1x1 device slot. The device internally keeps the compute block and
    // conv1x1-specific writeback path together, matching the spatial_top shape.
    conv1x1_top #(
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
        .output_zero_point_i(output_zero_point),
        .common_param_base_i(bias_base),
        .prelu_param_base_i(prelu_mult_base),
        .residual_param_base_i(residual_mult_base),
        .bias_i(bias),
        .multiplier_i(multiplier),
        .shift_i(shift),
        .zero_point_i(zero_point),
        .prelu_multiplier_i(prelu_multiplier),
        .prelu_shift_i(prelu_shift),
        .residual_multiplier_i(residual_multiplier),
        .residual_shift_i(residual_shift),
        .residual_zero_point_i(residual_zero_point),
        .gb_act_rd_valid_o(dev_act_rd_valid[CONV1X1_DEV]),
        .gb_act_rd_addr_o(dev_act_rd_addr[CONV1X1_DEV]),
        .gb_act_rd_data_i(dev_act_rd_data[CONV1X1_DEV]),
        .gb_wgt_rd_valid_o(dev_wgt_rd_valid[CONV1X1_DEV]),
        .gb_wgt_rd_addr_o(dev_wgt_rd_addr[CONV1X1_DEV]),
        .gb_wgt_rd_data_i(dev_wgt_rd_data[CONV1X1_DEV]),
        .gb_ao_wr_valid_o(dev_ao_wr_valid[CONV1X1_DEV]),
        .gb_ao_wr_addr_o(dev_ao_wr_addr[CONV1X1_DEV]),
        .gb_ao_wr_data_o(dev_ao_wr_data[CONV1X1_DEV]),
        .gb_ao_wr_mask_o(dev_ao_wr_mask[CONV1X1_DEV]),
        .quant_common_rd_en_o(conv_quant_common_rd_en),
        .quant_common_rd_addr_o(conv_quant_common_rd_addr),
        .quant_common_rd_valid_i(quant_common_rd_valid),
        .quant_prelu_rd_en_o(conv_quant_prelu_rd_en),
        .quant_prelu_rd_addr_o(conv_quant_prelu_rd_addr),
        .quant_prelu_rd_valid_i(quant_prelu_rd_valid),
        .quant_residual_rd_en_o(conv_quant_residual_rd_en),
        .quant_residual_rd_addr_o(conv_quant_residual_rd_addr),
        .quant_residual_rd_valid_i(quant_residual_rd_valid),
        .quant_param_bias_i(quant_param_bias),
        .quant_param_requant_multiplier_i(quant_param_requant_multiplier),
        .quant_param_requant_shift_i(quant_param_requant_shift),
        .quant_param_prelu_multiplier_i(quant_param_prelu_multiplier),
        .quant_param_prelu_shift_i(quant_param_prelu_shift),
        .quant_param_residual_multiplier_i(quant_param_residual_multiplier),
        .quant_param_residual_shift_i(quant_param_residual_shift),
        .quant_param_residual_zero_point_i(quant_param_residual_zero_point)
    );

    // Spatial 3x3 device slot. It receives metadata/base addresses from the
    // switcher and schedules per-channel postprocess parameters from
    // quant_param_mem internally.
    spatial_top #(
        .GB_ADDR_W(GB_ADDR_W),
        .GB_DATA_W(GB_DATA_W),
        .DATA_W(DATA_W),
        .OUT_W(OUT_W),
        .ACC_W(ACC_W),
        .ACT_DEPTH(SPATIAL_ACT_DEPTH),
        .WGT_DEPTH(SPATIAL_WGT_DEPTH),
        .ELEM_CNT_W(SPATIAL_ELEM_CNT_W),
        .BIAS_W(BIAS_W),
        .MUL_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W)
    ) u_spatial_dev (
        .clk(aclk),
        .rst_n(aresetn),
        .run_en_i(1'b1),
        .start_i(dev_start[SPATIAL_DEV]),
        .act_base_addr_i(act_base_addr),
        .wgt_base_addr_i(wgt_base_addr),
        .out_base_addr_i(out_base_addr),
        .output_elements_i(spatial_output_elements),
        .bias_base_i(bias_base),
        .requant_mult_base_i(requant_mult_base),
        .requant_shift_base_i(requant_shift_base),
        .prelu_mult_base_i(prelu_mult_base),
        .prelu_shift_base_i(prelu_shift_base),
        .residual_mult_base_i(residual_mult_base),
        .residual_shift_base_i(residual_shift_base),
        .residual_zero_point_base_i(residual_zero_point_base),
        .num_filter_code_i(num_filter_code),
        .ifmap_size_code_i(ifmap_size_code),
        .stride_i(stride),
        .pad_i(pad),
        .current_num_filter_i(spatial_current_num_filter),
        .post_mode_i({1'b0, mode}),
        .residual_en_i(residual_en),
        .residual_i(spatial_residual_stub),
        .output_zero_point_i(spatial_output_zero_point),
        .quant_common_rd_en_o(spatial_quant_common_rd_en),
        .quant_common_rd_addr_o(spatial_quant_common_rd_addr),
        .quant_common_rd_valid_i(quant_common_rd_valid),
        .quant_prelu_rd_en_o(spatial_quant_prelu_rd_en),
        .quant_prelu_rd_addr_o(spatial_quant_prelu_rd_addr),
        .quant_prelu_rd_valid_i(quant_prelu_rd_valid),
        .quant_residual_rd_en_o(spatial_quant_residual_rd_en),
        .quant_residual_rd_addr_o(spatial_quant_residual_rd_addr),
        .quant_residual_rd_valid_i(quant_residual_rd_valid),
        .quant_param_bias_i(quant_param_bias),
        .quant_param_requant_multiplier_i(quant_param_requant_multiplier),
        .quant_param_requant_shift_i(quant_param_requant_shift),
        .quant_param_prelu_multiplier_i(quant_param_prelu_multiplier),
        .quant_param_prelu_shift_i(quant_param_prelu_shift),
        .quant_param_residual_multiplier_i(quant_param_residual_multiplier),
        .quant_param_residual_shift_i(quant_param_residual_shift),
        .quant_param_residual_zero_point_i(quant_param_residual_zero_point),
        .gb_act_rd_en_o(dev_act_rd_valid[SPATIAL_DEV]),
        .gb_act_rd_addr_o(dev_act_rd_addr[SPATIAL_DEV]),
        .gb_act_rd_data_i(dev_act_rd_data[SPATIAL_DEV]),
        .gb_wgt_rd_en_o(dev_wgt_rd_valid[SPATIAL_DEV]),
        .gb_wgt_rd_addr_o(dev_wgt_rd_addr[SPATIAL_DEV]),
        .gb_wgt_rd_data_i(dev_wgt_rd_data[SPATIAL_DEV]),
        .gb_ao_wr_valid_o(dev_ao_wr_valid[SPATIAL_DEV]),
        .gb_ao_wr_addr_o(dev_ao_wr_addr[SPATIAL_DEV]),
        .gb_ao_wr_data_o(dev_ao_wr_data[SPATIAL_DEV]),
        .gb_ao_wr_mask_o(dev_ao_wr_mask[SPATIAL_DEV]),
        .busy_o(dev_busy[SPATIAL_DEV]),
        .done_o(dev_done[SPATIAL_DEV])
    );

    generate
        if (NUM_DEV > 1) begin : GEN_UNUSED_DEVICES
            for (genvar d = 0; d < NUM_DEV; d++) begin : GEN_DEV_TIEOFF
                if ((d != CONV1X1_DEV) && (d != SPATIAL_DEV)) begin : GEN_UNUSED
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
