`include "layer_defs.svh"

// Layer-level configuration memory.
//
// Formal path:
//   host/tool/C golden generates layer_config.hex
//   sync_rom reads one packed layer metadata word per layer_cnt_i
//
// This module intentionally does not contain profile-specific layer constants.
// Per-channel quantization values live in quant_param_mem; this ROM only stores
// layer metadata and the base addresses into global SRAM/parameter memories.
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
    parameter int LAYER_CONFIG_DEPTH = 128,
    parameter string LAYER_CONFIG_INIT_FILE = "",

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
    localparam int ROM_ADDR_W = (LAYER_CONFIG_DEPTH <= 1) ? 1 : $clog2(LAYER_CONFIG_DEPTH);

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

    logic [CFG_W-1:0] cfg_data_w;
    layer_cfg_t cfg_w;
    logic [ROM_ADDR_W-1:0] rd_addr_w;

    // Keep this reference so old scripts that still pass CONFIG_PROFILE do not
    // create unused-parameter warnings in some tools. The formal design uses
    // LAYER_CONFIG_INIT_FILE instead.
    logic config_profile_unused_w;
    assign config_profile_unused_w = (CONFIG_PROFILE != 0);

    assign rd_addr_w = layer_cnt_i[ROM_ADDR_W-1:0];

    sync_rom #(
        .DATA_W(CFG_W),
        .DEPTH(LAYER_CONFIG_DEPTH),
        .ADDR_W(ROM_ADDR_W),
        .INIT_FILE(LAYER_CONFIG_INIT_FILE)
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
        if (LAYER_CONFIG_DEPTH < 1) begin
            $fatal(1, "layer_config_mem requires LAYER_CONFIG_DEPTH >= 1");
        end
        if (LAYER_CONFIG_DEPTH > (1 << ROM_ADDR_W)) begin
            $fatal(1, "layer_config_mem ROM_ADDR_W is too small");
        end
        if (LAYER_CONFIG_INIT_FILE == "") begin
            $display("[layer_config_mem] WARNING: empty LAYER_CONFIG_INIT_FILE; schedule ROM defaults to NOP");
        end
        $display("[layer_config_mem] CFG_W=%0d bits, DEPTH=%0d, INIT_FILE=%s",
                 CFG_W, LAYER_CONFIG_DEPTH, LAYER_CONFIG_INIT_FILE);
    end
`endif
endmodule
