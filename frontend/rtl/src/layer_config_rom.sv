`include "layer_defs.svh"

module layer_config_rom #(
    parameter int ROW       = 14,
    parameter int COL       = 16,
    parameter int K_MAX     = 512,
    parameter int K_ADDR_W  = (K_MAX <= 1) ? 1 : $clog2(K_MAX),
    parameter int DATA_W    = 8,
    parameter int ACC_W     = 32,
    parameter int OUT_W     = 8,
    parameter int MULT_W    = 32,
    parameter int SHIFT_W   = 6,
    parameter int DIM_W     = 16,
    parameter int GB_DATA_W = 128,
    parameter int AO_DEPTH  = 8192,
    parameter int WGT_DEPTH = 8192,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int MAX_LAYER = 8,

    localparam int GB_LANES = GB_DATA_W / DATA_W,
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W
) (
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

    output postprocess_mode_t             mode_o,
    output logic signed [ACC_W-1:0]       bias_o       [COL],
    output logic signed [MULT_W-1:0]      multiplier_o [COL],
    output logic [SHIFT_W-1:0]            shift_o      [COL],
    output logic signed [OUT_W-1:0]       zero_point_o [COL],
    output logic signed [MULT_W-1:0]      prelu_multiplier_o [COL],
    output logic [SHIFT_W-1:0]            prelu_shift_o      [COL],
    output logic signed [MULT_W-1:0]      residual_multiplier_o [COL],
    output logic [SHIFT_W-1:0]            residual_shift_o      [COL],
    output logic signed [ACC_W-1:0]       residual_zero_point_o [COL]
);
    localparam int K_SIZE_W = K_ADDR_W + 1;

    // Current programmed slice from mobilefacenet_hw_simplified.csv:
    // layer 0: rows 20 + 22, conv1x1 28x28 128->64, residual add quant
    // layer 1: rows 23 + 25, conv1x1 28x28 64->128, PReLU quant
    localparam int IMG_28_M = 28 * 28;
    localparam int L0_K = 128;
    localparam int L0_N = 64;
    localparam int L1_K = 64;
    localparam int L1_N = 128;
    localparam int L0_WGT_WORDS = L0_K * ((L0_N + GB_LANES - 1) / GB_LANES);

    localparam logic [GB_ADDR_W-1:0] AO_IN_BASE  = '0;
    localparam logic [GB_ADDR_W-1:0] AO_OUT_BASE = {1'b1, {(GB_ADDR_W-1){1'b0}}};
    localparam logic [GB_ADDR_W-1:0] AO_RES_BASE = GB_ADDR_W'(8192);
    localparam logic [GB_ADDR_W-1:0] WGT0_BASE   = '0;
    localparam logic [GB_ADDR_W-1:0] WGT1_BASE   = GB_ADDR_W'(L0_WGT_WORDS);

    // This is intentionally written like a ROM interface but implemented as a
    // synthesizable combinational table for now. When the whole system is stable,
    // this block can become a generated ROM, or a config RAM loaded by host/DMA,
    // without changing the layer_switcher FSM/device mux structure.
    always_comb begin
        layer_valid_o   = 1'b0;
        layer_last_o    = 1'b0;
        layer_type_o    = LY_NOP;
        k_size_o        = '0;
        m_size_o        = '0;
        n_size_o        = '0;
        act_base_addr_o = '0;
        wgt_base_addr_o = '0;
        out_base_addr_o = '0;
        residual_en_o = 1'b0;
        residual_base_addr_o = '0;
        mode_o          = MODE_REQUANT;

        for (int c = 0; c < COL; c++) begin
            bias_o[c]             = '0;
            multiplier_o[c]       = MULT_W'(1);
            shift_o[c]            = '0;
            zero_point_o[c]       = '0;
            prelu_multiplier_o[c] = MULT_W'(1);
            prelu_shift_o[c]      = '0;
            residual_multiplier_o[c] = '0;
            residual_shift_o[c] = '0;
            residual_zero_point_o[c] = '0;
        end

        case (layer_cnt_i)
            MAX_LAYER'(0): begin
                layer_valid_o   = 1'b1;
                layer_last_o    = 1'b0;
                layer_type_o    = LY_CONV1X1;
                k_size_o        = K_SIZE_W'(L0_K);
                m_size_o        = DIM_W'(IMG_28_M);
                n_size_o        = DIM_W'(L0_N);
                act_base_addr_o = AO_IN_BASE;
                wgt_base_addr_o = WGT0_BASE;
                out_base_addr_o = AO_OUT_BASE;
                residual_en_o = 1'b1;
                residual_base_addr_o = AO_RES_BASE;
                mode_o          = MODE_RESIDUAL;
            end

            MAX_LAYER'(1): begin
                layer_valid_o   = 1'b1;
                layer_last_o    = 1'b1;
                layer_type_o    = LY_CONV1X1;
                k_size_o        = K_SIZE_W'(L1_K);
                m_size_o        = DIM_W'(IMG_28_M);
                n_size_o        = DIM_W'(L1_N);
                act_base_addr_o = AO_OUT_BASE;
                wgt_base_addr_o = WGT1_BASE;
                out_base_addr_o = AO_IN_BASE;
                mode_o          = MODE_PRELU;
            end

            default: ;
        endcase
    end
endmodule
