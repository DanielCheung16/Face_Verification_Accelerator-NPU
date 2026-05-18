`include "layer_defs.svh"

// Layer-level configuration memory.
//
// This module does not store per-channel quantization values. It stores only
// layer metadata and base addresses into the global quant_param_mem. The active
// layer top uses those base addresses to schedule per-channel parameter reads in
// the timing shape required by its own output stream.
module layer_config_mem #(
    parameter int K_MAX      = 512,
    parameter int K_ADDR_W   = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W     = 8,
    parameter int OUT_W      = 8,
    parameter int DIM_W      = 16,
    parameter int GB_DATA_W  = 128,
    parameter int AO_DEPTH   = 8192,
    parameter int WGT_DEPTH  = 8192,
    parameter int AO_ADDR_W  = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int PARAM_ADDR_W = 16,
    parameter int MAX_LAYER  = 8,
    parameter int CONFIG_PROFILE = 0,

    localparam int GB_LANES = GB_DATA_W / DATA_W,
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W
) (
    input  logic                    clk,
    input  logic                    rd_en_i,
    input  logic [MAX_LAYER-1:0]    layer_cnt_i,

    output logic                    layer_valid_o,
    output logic                    layer_last_o,
    output layer_type_t             layer_type_o,
    output logic [K_ADDR_W:0]       k_size_o,
    output logic [DIM_W-1:0]        m_size_o,
    output logic [DIM_W-1:0]        n_size_o,
    output logic [GB_ADDR_W-1:0]    act_base_addr_o,
    output logic [GB_ADDR_W-1:0]    wgt_base_addr_o,
    output logic [GB_ADDR_W-1:0]    out_base_addr_o,
    output logic                    residual_en_o,
    output logic [GB_ADDR_W-1:0]    residual_base_addr_o,

    output logic [2:0]              ifmap_size_code_o,
    output logic [1:0]              num_filter_code_o,
    output logic                    stride_o,
    output logic                    pad_o,
    output logic signed [DATA_W-1:0] pad_value_o,

    output postprocess_mode_t       mode_o,
    output logic signed [OUT_W-1:0] output_zero_point_o,
    output logic [PARAM_ADDR_W-1:0] bias_base_o,
    output logic [PARAM_ADDR_W-1:0] requant_mult_base_o,
    output logic [PARAM_ADDR_W-1:0] requant_shift_base_o,
    output logic [PARAM_ADDR_W-1:0] prelu_mult_base_o,
    output logic [PARAM_ADDR_W-1:0] prelu_shift_base_o,
    output logic [PARAM_ADDR_W-1:0] residual_mult_base_o,
    output logic [PARAM_ADDR_W-1:0] residual_shift_base_o,
    output logic [PARAM_ADDR_W-1:0] residual_zero_point_base_o
);
    localparam int K_SIZE_W = K_ADDR_W + 1;
    localparam int NUM_ROM_LAYERS = 4;
    localparam int ROM_ADDR_W = (NUM_ROM_LAYERS <= 1) ? 1 : $clog2(NUM_ROM_LAYERS);

    // CONFIG_PROFILE selects the scheduled verification/program image:
    //   0: rows 20 + 22, conv1x1 28x28 128->64, residual add quant
    //      rows 23 + 25, conv1x1 28x28 64->128, PReLU quant
    //   1: layer 0 only, conv1x1 28x28 128->64, requant
    //   2: layer 1 only, conv1x1 28x28 64->128, PReLU + requant
    //   3: layer 0 only, conv1x1 28x28 128->64, residual + requant
    //   4: layer 0 only, dwconv3x3 56x56x64, PReLU + requant
    //   5: conv1x1 -> conv1x1+PReLU -> dwconv3x3+PReLU -> conv1x1+residual
    //   6: conv1x1+residual -> conv1x1+PReLU -> dwconv3x3+PReLU -> conv1x1+residual
    //   7: layer 0 only, dwconv3x3 stride2 56x56x128 -> 28x28x128, PReLU + requant
    //   8: dwconv3x3 stride2 + PReLU -> conv1x1 + requant
    //   9: layer 0 only, first conv3x3 112x112x3 -> 56x56x64, PReLU + requant
    //  10: first conv3x3 + following dwconv3x3, both PReLU + requant
    localparam int IMG_28_M = 28 * 28;
    localparam int IMG_56_M = 56 * 56;
    localparam int FIRST_CONV_K = 3;
    localparam int FIRST_CONV_N = 64;
    localparam int L0_K = 128;
    localparam int L0_N = 64;
    localparam int L1_K = 64;
    localparam int L1_N = 128;
    localparam int DW0_N = 64;
    localparam int DW1_N = 128;
    localparam int L0_WGT_WORDS = L0_K * ((L0_N + GB_LANES - 1) / GB_LANES);
    localparam int JOINT_M = IMG_28_M;
    localparam int JOINT_C64 = 64;
    localparam int JOINT_C128 = 128;

    localparam logic [GB_ADDR_W-1:0] AO_IN_BASE  = '0;
    localparam logic [GB_ADDR_W-1:0] AO_OUT_BASE = {1'b1, {(GB_ADDR_W-1){1'b0}}};
    localparam logic [GB_ADDR_W-1:0] AO_RES_BASE = GB_ADDR_W'(8192);
    localparam logic [GB_ADDR_W-1:0] SPATIAL_OUT_BASE = GB_ADDR_W'(300000);
    localparam logic [GB_ADDR_W-1:0] WGT0_BASE   = '0;
    localparam logic [GB_ADDR_W-1:0] WGT1_BASE   = GB_ADDR_W'(L0_WGT_WORDS);
    localparam logic [GB_ADDR_W-1:0] JOINT_AO_BASE0 = GB_ADDR_W'(0);
    localparam logic [GB_ADDR_W-1:0] JOINT_AO_BASE1 = GB_ADDR_W'(10000);
    localparam logic [GB_ADDR_W-1:0] JOINT_AO_BASE2 = GB_ADDR_W'(20000);
    localparam logic [GB_ADDR_W-1:0] JOINT_AO_BASE3 = GB_ADDR_W'(30000);
    localparam logic [GB_ADDR_W-1:0] JOINT_AO_BASE4 = GB_ADDR_W'(40000);
    localparam logic [GB_ADDR_W-1:0] JOINT_WGT_BASE0 = GB_ADDR_W'(0);
    localparam logic [GB_ADDR_W-1:0] JOINT_WGT_BASE1 = GB_ADDR_W'(2000);
    localparam logic [GB_ADDR_W-1:0] JOINT_WGT_BASE2 = GB_ADDR_W'(4000);
    localparam logic [GB_ADDR_W-1:0] JOINT_WGT_BASE3 = GB_ADDR_W'(6000);

    localparam logic [PARAM_ADDR_W-1:0] L0_PARAM_BASE = PARAM_ADDR_W'(0);
    localparam logic [PARAM_ADDR_W-1:0] L1_PARAM_BASE = PARAM_ADDR_W'(64);
    localparam logic [PARAM_ADDR_W-1:0] P5_L0_PARAM_BASE = PARAM_ADDR_W'(384);
    localparam logic [PARAM_ADDR_W-1:0] P5_L1_PARAM_BASE = PARAM_ADDR_W'(448);
    localparam logic [PARAM_ADDR_W-1:0] P5_L2_PARAM_BASE = PARAM_ADDR_W'(576);
    localparam logic [PARAM_ADDR_W-1:0] P5_L3_PARAM_BASE = PARAM_ADDR_W'(704);
    localparam logic [PARAM_ADDR_W-1:0] P6_L0_PARAM_BASE = PARAM_ADDR_W'(1024);
    localparam logic [PARAM_ADDR_W-1:0] P6_L1_PARAM_BASE = PARAM_ADDR_W'(1088);
    localparam logic [PARAM_ADDR_W-1:0] P6_L2_PARAM_BASE = PARAM_ADDR_W'(1216);
    localparam logic [PARAM_ADDR_W-1:0] P6_L3_PARAM_BASE = PARAM_ADDR_W'(1344);
    localparam logic [PARAM_ADDR_W-1:0] P8_L0_PARAM_BASE = PARAM_ADDR_W'(256);
    localparam logic [PARAM_ADDR_W-1:0] P8_L1_PARAM_BASE = PARAM_ADDR_W'(384);
    localparam logic signed [OUT_W-1:0] L0_OUTPUT_ZERO_POINT = -$signed(OUT_W'(18));
    localparam logic signed [OUT_W-1:0] L1_OUTPUT_ZERO_POINT = -$signed(OUT_W'(77));
    localparam logic signed [OUT_W-1:0] DW0_OUTPUT_ZERO_POINT = -$signed(OUT_W'(57));
    localparam logic signed [OUT_W-1:0] DW1_OUTPUT_ZERO_POINT = -$signed(OUT_W'(45));
    localparam logic signed [OUT_W-1:0] P5_L0_OUTPUT_ZERO_POINT = -$signed(OUT_W'(27));
    localparam logic signed [OUT_W-1:0] P5_L1_OUTPUT_ZERO_POINT = -$signed(OUT_W'(61));
    localparam logic signed [OUT_W-1:0] P5_L2_OUTPUT_ZERO_POINT = -$signed(OUT_W'(85));
    localparam logic signed [OUT_W-1:0] P5_L3_OUTPUT_ZERO_POINT = -$signed(OUT_W'(18));
    localparam logic signed [OUT_W-1:0] P6_L0_OUTPUT_ZERO_POINT = -$signed(OUT_W'(5));
    localparam logic signed [OUT_W-1:0] P6_L1_OUTPUT_ZERO_POINT = -$signed(OUT_W'(86));
    localparam logic signed [OUT_W-1:0] P6_L2_OUTPUT_ZERO_POINT = -$signed(OUT_W'(108));
    localparam logic signed [OUT_W-1:0] P6_L3_OUTPUT_ZERO_POINT = -$signed(OUT_W'(13));
    // Real-value zero padding in asymmetric int8 maps to -input_zero_point.
    localparam logic signed [DATA_W-1:0] FIRST_CONV_PAD_VALUE = $signed(DATA_W'(10));
    localparam logic signed [OUT_W-1:0] FIRST_CONV_OUTPUT_ZERO_POINT = -$signed(OUT_W'(31));
    localparam logic signed [DATA_W-1:0] DW0_PAD_VALUE = -$signed(DATA_W'(31));
    localparam logic signed [DATA_W-1:0] DW1_PAD_VALUE = -$signed(DATA_W'(87));
    localparam logic signed [DATA_W-1:0] P5_L2_PAD_VALUE = -$signed(DATA_W'(61));
    localparam logic signed [DATA_W-1:0] P6_L2_PAD_VALUE = -$signed(DATA_W'(86));

    typedef struct packed {
        logic                    layer_valid;
        logic                    layer_last;
        layer_type_t             layer_type;
        logic [K_SIZE_W-1:0]     k_size;
        logic [DIM_W-1:0]        m_size;
        logic [DIM_W-1:0]        n_size;
        logic [GB_ADDR_W-1:0]    act_base_addr;
        logic [GB_ADDR_W-1:0]    wgt_base_addr;
        logic [GB_ADDR_W-1:0]    out_base_addr;
        logic                    residual_en;
        logic [GB_ADDR_W-1:0]    residual_base_addr;
        logic [2:0]              ifmap_size_code;
        logic [1:0]              num_filter_code;
        logic                    stride;
        logic                    pad;
        logic signed [DATA_W-1:0] pad_value;
        postprocess_mode_t       mode;
        logic signed [OUT_W-1:0] output_zero_point;
        logic [PARAM_ADDR_W-1:0] bias_base;
        logic [PARAM_ADDR_W-1:0] requant_mult_base;
        logic [PARAM_ADDR_W-1:0] requant_shift_base;
        logic [PARAM_ADDR_W-1:0] prelu_mult_base;
        logic [PARAM_ADDR_W-1:0] prelu_shift_base;
        logic [PARAM_ADDR_W-1:0] residual_mult_base;
        logic [PARAM_ADDR_W-1:0] residual_shift_base;
        logic [PARAM_ADDR_W-1:0] residual_zero_point_base;
    } layer_cfg_t;

    localparam int CFG_W = $bits(layer_cfg_t);

    function automatic layer_cfg_t default_cfg();
        layer_cfg_t cfg;
        begin
            cfg = '0;
            cfg.layer_type = LY_NOP;
            cfg.mode = MODE_REQUANT;
            default_cfg = cfg;
        end
    endfunction

    function automatic layer_cfg_t layer0_cfg();
        layer_cfg_t cfg;
        begin
            cfg = default_cfg();
            cfg.layer_valid = 1'b1;
            cfg.layer_last = ((CONFIG_PROFILE != 0) && (CONFIG_PROFILE != 5) &&
                              (CONFIG_PROFILE != 6) && (CONFIG_PROFILE != 8) &&
                              (CONFIG_PROFILE != 10));
            cfg.layer_type = LY_CONV1X1;
            cfg.m_size = DIM_W'(IMG_28_M);
            cfg.act_base_addr = AO_IN_BASE;
            cfg.wgt_base_addr = WGT0_BASE;
            cfg.out_base_addr = AO_OUT_BASE;

            if (CONFIG_PROFILE == 5) begin
                cfg.k_size = K_SIZE_W'(JOINT_C128);
                cfg.m_size = DIM_W'(JOINT_M);
                cfg.n_size = DIM_W'(JOINT_C64);
                cfg.act_base_addr = JOINT_AO_BASE0;
                cfg.wgt_base_addr = JOINT_WGT_BASE0;
                cfg.out_base_addr = JOINT_AO_BASE1;
                cfg.mode = MODE_REQUANT;
                cfg.output_zero_point = P5_L0_OUTPUT_ZERO_POINT;
                cfg.bias_base = P5_L0_PARAM_BASE;
                cfg.requant_mult_base = P5_L0_PARAM_BASE;
                cfg.requant_shift_base = P5_L0_PARAM_BASE;
                cfg.prelu_mult_base = P5_L0_PARAM_BASE;
                cfg.prelu_shift_base = P5_L0_PARAM_BASE;
            end else if (CONFIG_PROFILE == 6) begin
                cfg.k_size = K_SIZE_W'(JOINT_C128);
                cfg.m_size = DIM_W'(JOINT_M);
                cfg.n_size = DIM_W'(JOINT_C64);
                cfg.act_base_addr = JOINT_AO_BASE0;
                cfg.wgt_base_addr = JOINT_WGT_BASE0;
                cfg.out_base_addr = JOINT_AO_BASE1;
                cfg.residual_en = 1'b1;
                cfg.residual_base_addr = JOINT_AO_BASE2;
                cfg.mode = MODE_RESIDUAL;
                cfg.output_zero_point = P6_L0_OUTPUT_ZERO_POINT;
                cfg.bias_base = P6_L0_PARAM_BASE;
                cfg.requant_mult_base = P6_L0_PARAM_BASE;
                cfg.requant_shift_base = P6_L0_PARAM_BASE;
                cfg.prelu_mult_base = P6_L0_PARAM_BASE;
                cfg.prelu_shift_base = P6_L0_PARAM_BASE;
                cfg.residual_mult_base = P6_L0_PARAM_BASE;
                cfg.residual_shift_base = P6_L0_PARAM_BASE;
                cfg.residual_zero_point_base = P6_L0_PARAM_BASE;
            end else if ((CONFIG_PROFILE == 9) || (CONFIG_PROFILE == 10)) begin
                cfg.layer_type = LY_CONV3X3;
                cfg.k_size = K_SIZE_W'(FIRST_CONV_K);
                cfg.m_size = DIM_W'(IMG_56_M);
                cfg.n_size = DIM_W'(FIRST_CONV_N);
                cfg.out_base_addr = (CONFIG_PROFILE == 10) ? JOINT_AO_BASE2 : SPATIAL_OUT_BASE;
                cfg.mode = MODE_PRELU;
                cfg.output_zero_point = FIRST_CONV_OUTPUT_ZERO_POINT;
                cfg.ifmap_size_code = 3'd4; // 112x112 input, stride2 -> 56x56 output
                cfg.num_filter_code = 2'd0; // 64 output channels
                cfg.stride = 1'b1;
                cfg.pad = 1'b1;
                cfg.pad_value = FIRST_CONV_PAD_VALUE;
                cfg.bias_base = L0_PARAM_BASE;
                cfg.requant_mult_base = L0_PARAM_BASE;
                cfg.requant_shift_base = L0_PARAM_BASE;
                cfg.prelu_mult_base = L0_PARAM_BASE;
                cfg.prelu_shift_base = L0_PARAM_BASE;
            end else if ((CONFIG_PROFILE == 4) || (CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) begin
                cfg.layer_type = LY_DWCONV3X3;
                cfg.k_size = ((CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) ?
                             K_SIZE_W'(DW1_N) : K_SIZE_W'(DW0_N);
                cfg.m_size = ((CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) ?
                             DIM_W'(IMG_28_M) : DIM_W'(IMG_56_M);
                cfg.n_size = ((CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) ?
                             DIM_W'(DW1_N) : DIM_W'(DW0_N);
                cfg.act_base_addr = (CONFIG_PROFILE == 8) ? JOINT_AO_BASE0 : AO_IN_BASE;
                cfg.wgt_base_addr = (CONFIG_PROFILE == 8) ? JOINT_WGT_BASE0 : WGT0_BASE;
                cfg.out_base_addr = (CONFIG_PROFILE == 8) ? JOINT_AO_BASE3 : SPATIAL_OUT_BASE;
                cfg.mode = MODE_PRELU;
                cfg.output_zero_point = ((CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) ?
                                        DW1_OUTPUT_ZERO_POINT : DW0_OUTPUT_ZERO_POINT;
                cfg.ifmap_size_code = 3'd3; // 56x56
                cfg.num_filter_code = ((CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) ?
                                      2'd1 : 2'd0; // 64/128 channels
                cfg.stride = (CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8); // stride 1/2
                cfg.pad = 1'b1;             // same padding
                cfg.pad_value = ((CONFIG_PROFILE == 7) || (CONFIG_PROFILE == 8)) ?
                                DW1_PAD_VALUE : DW0_PAD_VALUE;
                cfg.bias_base = (CONFIG_PROFILE == 8) ? P8_L0_PARAM_BASE : L0_PARAM_BASE;
                cfg.requant_mult_base = cfg.bias_base;
                cfg.requant_shift_base = cfg.bias_base;
                cfg.prelu_mult_base = cfg.bias_base;
                cfg.prelu_shift_base = cfg.bias_base;
            end else if (CONFIG_PROFILE == 2) begin
                cfg.k_size = K_SIZE_W'(L1_K);
                cfg.n_size = DIM_W'(L1_N);
                cfg.mode = MODE_PRELU;
                cfg.output_zero_point = L1_OUTPUT_ZERO_POINT;
                cfg.bias_base = L1_PARAM_BASE;
                cfg.requant_mult_base = L1_PARAM_BASE;
                cfg.requant_shift_base = L1_PARAM_BASE;
                cfg.prelu_mult_base = L1_PARAM_BASE;
                cfg.prelu_shift_base = L1_PARAM_BASE;
            end else begin
                cfg.k_size = K_SIZE_W'(L0_K);
                cfg.n_size = DIM_W'(L0_N);
                cfg.residual_en = (CONFIG_PROFILE == 1) ? 1'b0 : 1'b1;
                cfg.residual_base_addr = (CONFIG_PROFILE == 1) ? '0 : AO_RES_BASE;
                cfg.mode = (CONFIG_PROFILE == 1) ? MODE_REQUANT : MODE_RESIDUAL;
                cfg.output_zero_point = L0_OUTPUT_ZERO_POINT;
                cfg.bias_base = L0_PARAM_BASE;
                cfg.requant_mult_base = L0_PARAM_BASE;
                cfg.requant_shift_base = L0_PARAM_BASE;
                cfg.prelu_mult_base = L0_PARAM_BASE;
                cfg.prelu_shift_base = L0_PARAM_BASE;
                cfg.residual_mult_base = L0_PARAM_BASE;
                cfg.residual_shift_base = L0_PARAM_BASE;
                cfg.residual_zero_point_base = L0_PARAM_BASE;
            end
            layer0_cfg = cfg;
        end
    endfunction

    function automatic layer_cfg_t layer1_cfg();
        layer_cfg_t cfg;
        begin
            cfg = default_cfg();
            cfg.layer_valid = (CONFIG_PROFILE == 0) || (CONFIG_PROFILE == 5) ||
                              (CONFIG_PROFILE == 6) || (CONFIG_PROFILE == 8) ||
                              (CONFIG_PROFILE == 10);
            cfg.layer_last = (CONFIG_PROFILE == 0) || (CONFIG_PROFILE == 8) ||
                             (CONFIG_PROFILE == 10);
            cfg.layer_type = LY_CONV1X1;
            cfg.k_size = K_SIZE_W'(L1_K);
            cfg.m_size = DIM_W'(IMG_28_M);
            cfg.n_size = DIM_W'(L1_N);
            cfg.act_base_addr = AO_OUT_BASE;
            cfg.wgt_base_addr = WGT1_BASE;
            cfg.out_base_addr = AO_IN_BASE;
            cfg.mode = MODE_PRELU;
            cfg.output_zero_point = L1_OUTPUT_ZERO_POINT;
            cfg.bias_base = L1_PARAM_BASE;
            cfg.requant_mult_base = L1_PARAM_BASE;
            cfg.requant_shift_base = L1_PARAM_BASE;
            cfg.prelu_mult_base = L1_PARAM_BASE;
            cfg.prelu_shift_base = L1_PARAM_BASE;
            if (CONFIG_PROFILE == 5) begin
                cfg.k_size = K_SIZE_W'(JOINT_C64);
                cfg.m_size = DIM_W'(JOINT_M);
                cfg.n_size = DIM_W'(JOINT_C128);
                cfg.act_base_addr = JOINT_AO_BASE1;
                cfg.wgt_base_addr = JOINT_WGT_BASE1;
                cfg.out_base_addr = JOINT_AO_BASE2;
                cfg.output_zero_point = P5_L1_OUTPUT_ZERO_POINT;
                cfg.bias_base = P5_L1_PARAM_BASE;
                cfg.requant_mult_base = P5_L1_PARAM_BASE;
                cfg.requant_shift_base = P5_L1_PARAM_BASE;
                cfg.prelu_mult_base = P5_L1_PARAM_BASE;
                cfg.prelu_shift_base = P5_L1_PARAM_BASE;
            end else if (CONFIG_PROFILE == 6) begin
                cfg.k_size = K_SIZE_W'(JOINT_C64);
                cfg.m_size = DIM_W'(JOINT_M);
                cfg.n_size = DIM_W'(JOINT_C128);
                cfg.act_base_addr = JOINT_AO_BASE1;
                cfg.wgt_base_addr = JOINT_WGT_BASE1;
                cfg.out_base_addr = JOINT_AO_BASE2;
                cfg.output_zero_point = P6_L1_OUTPUT_ZERO_POINT;
                cfg.bias_base = P6_L1_PARAM_BASE;
                cfg.requant_mult_base = P6_L1_PARAM_BASE;
                cfg.requant_shift_base = P6_L1_PARAM_BASE;
                cfg.prelu_mult_base = P6_L1_PARAM_BASE;
                cfg.prelu_shift_base = P6_L1_PARAM_BASE;
            end else if (CONFIG_PROFILE == 8) begin
                cfg.k_size = K_SIZE_W'(JOINT_C128);
                cfg.m_size = DIM_W'(JOINT_M);
                cfg.n_size = DIM_W'(JOINT_C64);
                cfg.act_base_addr = JOINT_AO_BASE3;
                cfg.wgt_base_addr = JOINT_WGT_BASE1;
                cfg.out_base_addr = JOINT_AO_BASE4;
                cfg.mode = MODE_REQUANT;
                cfg.output_zero_point = P5_L0_OUTPUT_ZERO_POINT;
                cfg.bias_base = P8_L1_PARAM_BASE;
                cfg.requant_mult_base = P8_L1_PARAM_BASE;
                cfg.requant_shift_base = P8_L1_PARAM_BASE;
                cfg.prelu_mult_base = P8_L1_PARAM_BASE;
                cfg.prelu_shift_base = P8_L1_PARAM_BASE;
            end else if (CONFIG_PROFILE == 10) begin
                cfg.layer_type = LY_DWCONV3X3;
                cfg.k_size = K_SIZE_W'(DW0_N);
                cfg.m_size = DIM_W'(IMG_56_M);
                cfg.n_size = DIM_W'(DW0_N);
                cfg.act_base_addr = JOINT_AO_BASE2;
                cfg.wgt_base_addr = JOINT_WGT_BASE1;
                cfg.out_base_addr = JOINT_AO_BASE4;
                cfg.mode = MODE_PRELU;
                cfg.output_zero_point = DW0_OUTPUT_ZERO_POINT;
                cfg.ifmap_size_code = 3'd3; // 56x56
                cfg.num_filter_code = 2'd0; // 64 channels
                cfg.stride = 1'b0;
                cfg.pad = 1'b1;
                cfg.pad_value = DW0_PAD_VALUE;
                cfg.bias_base = L1_PARAM_BASE;
                cfg.requant_mult_base = L1_PARAM_BASE;
                cfg.requant_shift_base = L1_PARAM_BASE;
                cfg.prelu_mult_base = L1_PARAM_BASE;
                cfg.prelu_shift_base = L1_PARAM_BASE;
            end
            layer1_cfg = cfg;
        end
    endfunction

    function automatic layer_cfg_t layer2_cfg();
        layer_cfg_t cfg;
        begin
            cfg = default_cfg();
            cfg.layer_valid = (CONFIG_PROFILE == 5) || (CONFIG_PROFILE == 6);
            cfg.layer_last = 1'b0;
            cfg.layer_type = LY_DWCONV3X3;
            cfg.k_size = '0;
            cfg.m_size = DIM_W'(JOINT_M);
            cfg.n_size = DIM_W'(JOINT_C128);
            cfg.act_base_addr = JOINT_AO_BASE2;
            cfg.wgt_base_addr = JOINT_WGT_BASE2;
            cfg.out_base_addr = JOINT_AO_BASE3;
            cfg.mode = MODE_PRELU;
            cfg.output_zero_point = (CONFIG_PROFILE == 6) ? P6_L2_OUTPUT_ZERO_POINT : P5_L2_OUTPUT_ZERO_POINT;
            cfg.ifmap_size_code = 3'd2; // 28x28
            cfg.num_filter_code = 2'd1; // 128 channels
            cfg.stride = 1'b0;
            cfg.pad = 1'b1;
            cfg.pad_value = (CONFIG_PROFILE == 6) ? P6_L2_PAD_VALUE : P5_L2_PAD_VALUE;
            cfg.bias_base = (CONFIG_PROFILE == 6) ? P6_L2_PARAM_BASE : P5_L2_PARAM_BASE;
            cfg.requant_mult_base = cfg.bias_base;
            cfg.requant_shift_base = cfg.bias_base;
            cfg.prelu_mult_base = cfg.bias_base;
            cfg.prelu_shift_base = cfg.bias_base;
            layer2_cfg = cfg;
        end
    endfunction

    function automatic layer_cfg_t layer3_cfg();
        layer_cfg_t cfg;
        begin
            cfg = default_cfg();
            cfg.layer_valid = (CONFIG_PROFILE == 5) || (CONFIG_PROFILE == 6);
            cfg.layer_last = 1'b1;
            cfg.layer_type = LY_CONV1X1;
            cfg.k_size = K_SIZE_W'(JOINT_C128);
            cfg.m_size = DIM_W'(JOINT_M);
            cfg.n_size = DIM_W'(JOINT_C64);
            cfg.act_base_addr = JOINT_AO_BASE3;
            cfg.wgt_base_addr = JOINT_WGT_BASE3;
            cfg.out_base_addr = JOINT_AO_BASE4;
            cfg.residual_en = 1'b1;
            cfg.residual_base_addr = JOINT_AO_BASE1;
            cfg.mode = MODE_RESIDUAL;
            cfg.output_zero_point = (CONFIG_PROFILE == 6) ? P6_L3_OUTPUT_ZERO_POINT : P5_L3_OUTPUT_ZERO_POINT;
            cfg.bias_base = (CONFIG_PROFILE == 6) ? P6_L3_PARAM_BASE : P5_L3_PARAM_BASE;
            cfg.requant_mult_base = cfg.bias_base;
            cfg.requant_shift_base = cfg.bias_base;
            cfg.prelu_mult_base = cfg.bias_base;
            cfg.prelu_shift_base = cfg.bias_base;
            cfg.residual_mult_base = cfg.bias_base;
            cfg.residual_shift_base = cfg.bias_base;
            cfg.residual_zero_point_base = cfg.bias_base;
            layer3_cfg = cfg;
        end
    endfunction

    localparam layer_cfg_t LAYER0_CFG = layer0_cfg();
    localparam layer_cfg_t LAYER1_CFG = layer1_cfg();
    localparam layer_cfg_t LAYER2_CFG = layer2_cfg();
    localparam layer_cfg_t LAYER3_CFG = layer3_cfg();

    logic [CFG_W-1:0] cfg_data_w;
    layer_cfg_t cfg_w;
    logic [ROM_ADDR_W-1:0] rd_addr_w;

    // layer_config_mem only generates the ROM read address. The ROM itself owns
    // storage width/depth and the single-read-port timing.
    assign rd_addr_w = layer_cnt_i[ROM_ADDR_W-1:0];

    sync_rom #(
        .DATA_W(CFG_W),
        .DEPTH(NUM_ROM_LAYERS),
        .ADDR_W(ROM_ADDR_W),
        .INIT_0(CFG_W'(LAYER0_CFG)),
        .INIT_1(CFG_W'(LAYER1_CFG)),
        .INIT_2(CFG_W'(LAYER2_CFG)),
        .INIT_3(CFG_W'(LAYER3_CFG))
    ) u_cfg_rom (
        .clk(clk),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_w),
        .rd_data_o(cfg_data_w)
    );

    assign cfg_w = layer_cfg_t'(cfg_data_w);

    assign layer_valid_o = cfg_w.layer_valid;
    assign layer_last_o = cfg_w.layer_last;
    assign layer_type_o = cfg_w.layer_type;
    assign k_size_o = cfg_w.k_size;
    assign m_size_o = cfg_w.m_size;
    assign n_size_o = cfg_w.n_size;
    assign act_base_addr_o = cfg_w.act_base_addr;
    assign wgt_base_addr_o = cfg_w.wgt_base_addr;
    assign out_base_addr_o = cfg_w.out_base_addr;
    assign residual_en_o = cfg_w.residual_en;
    assign residual_base_addr_o = cfg_w.residual_base_addr;
    assign ifmap_size_code_o = cfg_w.ifmap_size_code;
    assign num_filter_code_o = cfg_w.num_filter_code;
    assign stride_o = cfg_w.stride;
    assign pad_o = cfg_w.pad;
    assign pad_value_o = cfg_w.pad_value;
    assign mode_o = cfg_w.mode;
    assign output_zero_point_o = cfg_w.output_zero_point;
    assign bias_base_o = cfg_w.bias_base;
    assign requant_mult_base_o = cfg_w.requant_mult_base;
    assign requant_shift_base_o = cfg_w.requant_shift_base;
    assign prelu_mult_base_o = cfg_w.prelu_mult_base;
    assign prelu_shift_base_o = cfg_w.prelu_shift_base;
    assign residual_mult_base_o = cfg_w.residual_mult_base;
    assign residual_shift_base_o = cfg_w.residual_shift_base;
    assign residual_zero_point_base_o = cfg_w.residual_zero_point_base;

`ifndef SYNTHESIS
    initial begin
        if (NUM_ROM_LAYERS > (1 << ROM_ADDR_W)) begin
            $fatal(1, "layer_config_mem ROM_ADDR_W is too small");
        end
        $display("[layer_config_mem] CFG_W=%0d bits, DEPTH=%0d", CFG_W, NUM_ROM_LAYERS);
    end
`endif
endmodule
