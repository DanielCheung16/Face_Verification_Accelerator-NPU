`include "layer_defs.svh"

module layer_switcher #(
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
    parameter int PARAM_ADDR_W = 16,
    parameter int GB_DATA_W = 128,
    parameter int AO_DEPTH  = 8192,
    parameter int WGT_DEPTH = 8192,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int NUM_DEV = 1,
    parameter int MAX_LAYER = 8,
    parameter int LAYER_CONFIG_PROFILE = 0,

    localparam int GB_LANES = GB_DATA_W / DATA_W,
    localparam int AO_MASK_W = GB_DATA_W / DATA_W,
    localparam int WGT_MASK_W = GB_DATA_W / DATA_W,
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W,
    localparam int MAX_RC = (ROW > COL) ? ROW : COL,
    localparam int BANK_ADDR_W = (MAX_RC <= 1) ? 1 : $clog2(MAX_RC),
    localparam int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW),
    localparam int FINAL_VEC = 128
) (
    input  logic clk,
    input  logic rst_n,

    // sys_start/sys_done are for this scheduled model slice, not a tile.
    input  logic sys_start,
    output logic sys_done,

    output logic start_o [NUM_DEV],
    input  wire logic busy_i  [NUM_DEV],
    input  wire logic done_i  [NUM_DEV],

    output logic [K_ADDR_W:0]     k_size_o,
    output logic [DIM_W-1:0]      m_size_o,
    output logic [DIM_W-1:0]      n_size_o,
    output logic [GB_ADDR_W-1:0]  act_base_addr_o,
    output logic [GB_ADDR_W-1:0]  wgt_base_addr_o,
    output logic [GB_ADDR_W-1:0]  out_base_addr_o,
    output logic                  residual_en_o,
    output logic [GB_ADDR_W-1:0]  residual_base_addr_o,
    output logic [MAX_LAYER-1:0]  layer_idx_o,
    output layer_type_t           layer_type_o,

    output logic [1:0]                    mode_o,
    output logic [2:0]                    ifmap_size_code_o,
    output logic [1:0]                    num_filter_code_o,
    output logic                          stride_o,
    output logic                          pad_o,
    output logic signed [DATA_W-1:0]      pad_value_o,
    output logic signed [OUT_W-1:0]       output_zero_point_o,
    output logic [PARAM_ADDR_W-1:0]       bias_base_o,
    output logic [PARAM_ADDR_W-1:0]       requant_mult_base_o,
    output logic [PARAM_ADDR_W-1:0]       requant_shift_base_o,
    output logic [PARAM_ADDR_W-1:0]       prelu_mult_base_o,
    output logic [PARAM_ADDR_W-1:0]       prelu_shift_base_o,
    output logic [PARAM_ADDR_W-1:0]       residual_mult_base_o,
    output logic [PARAM_ADDR_W-1:0]       residual_shift_base_o,
    output logic [PARAM_ADDR_W-1:0]       residual_zero_point_base_o,

    input  wire logic                     dev_act_rd_valid_i [NUM_DEV],
    input  wire logic [GB_ADDR_W-1:0]     dev_act_rd_addr_i  [NUM_DEV],
    output logic [GB_DATA_W-1:0]     dev_act_rd_data_o  [NUM_DEV],
    input  wire logic                     dev_ao_wr_valid_i  [NUM_DEV],
    input  wire logic [GB_ADDR_W-1:0]     dev_ao_wr_addr_i   [NUM_DEV],
    input  wire logic [GB_DATA_W-1:0]     dev_ao_wr_data_i   [NUM_DEV],
    input  wire logic [AO_MASK_W-1:0]     dev_ao_wr_mask_i   [NUM_DEV],

    input  wire logic                     dev_wgt_rd_valid_i [NUM_DEV],
    input  wire logic [GB_ADDR_W-1:0]     dev_wgt_rd_addr_i  [NUM_DEV],
    output logic [GB_DATA_W-1:0]     dev_wgt_rd_data_o  [NUM_DEV],

    output logic                     gb_act_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_act_rd_data_i,
    output logic                     gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]     gb_ao_wr_data_o,
    output logic [AO_MASK_W-1:0]     gb_ao_wr_mask_o,

    output logic                     gb_wgt_rd_valid_o,
    output logic [GB_ADDR_W-1:0]     gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0]     gb_wgt_rd_data_i,

    output logic                     final_valid_o,
    output logic [FINAL_VEC-1:0]     final_vec_o
);
    localparam int DEV_IDX_W = (NUM_DEV <= 1) ? 1 : $clog2(NUM_DEV);
    localparam logic [DEV_IDX_W-1:0] CONV1X1_DEV = '0;
    localparam logic [DEV_IDX_W-1:0] SPATIAL_DEV = (NUM_DEV > 1) ? DEV_IDX_W'(1) : '0;

    typedef enum logic [2:0] {
        IDLE,
        FETCH_CONFIG,
        DISPATCH,
        WAIT_DEV,
        DONE
    } state_t;

    state_t state, state_nxt;
    logic [MAX_LAYER-1:0] layer_cnt_r, layer_cnt_w;
    logic seen_busy_r, seen_busy_w;
    layer_type_t layer_type_w;

    logic active_dev_valid_w;
    logic [DEV_IDX_W-1:0] active_dev_idx_w;
    logic layer_valid_w;
    logic layer_last_w;
    logic active_done_w;
    logic config_rd_en_w;
    logic [MAX_LAYER-1:0] config_rd_idx_w;

    assign active_done_w = active_dev_valid_w && seen_busy_r && done_i[active_dev_idx_w];
    assign layer_idx_o = layer_cnt_r;
    assign layer_type_o = layer_type_w;

`ifndef SYNTHESIS
    initial begin
        if (NUM_DEV < 1) begin
            $fatal(1, "layer_switcher requires NUM_DEV >= 1");
        end
        if (NUM_DEV < 1 + int'(CONV1X1_DEV)) begin
            $fatal(1, "layer_switcher requires a conv1x1 device at CONV1X1_DEV");
        end
        if (GB_DATA_W % DATA_W != 0) begin
            $fatal(1, "layer_switcher requires GB_DATA_W to be an integer multiple of DATA_W");
        end
    end
`endif

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            layer_cnt_r <= '0;
            seen_busy_r <= 1'b0;
        end else begin
            state     <= state_nxt;
            layer_cnt_r <= layer_cnt_w;
            seen_busy_r <= seen_busy_w;
        end
    end

    // -------------------------------------------------------------------------
    // State transition control
    //
    // Handshake rules:
    // 1. sys_start/sys_done are model-slice level signals. sys_start is held by
    //    the host until sys_done is observed. sys_done stays high in DONE until
    //    sys_start drops.
    // 2. start_o[dev] is a one-cycle pulse generated in DISPATCH for the decoded
    //    active device.
    // 3. After start_o, the device should raise busy_i[dev] while it owns the
    //    layer. The switcher records this in seen_busy_r.
    // 4. done_i[dev] is accepted only after busy_i[dev] has been seen. This
    //    prevents an idle-high done signal from accidentally completing a layer.
    // 5. When accepted done_i arrives, layer_cnt_r advances to the next layer or
    //    the FSM enters DONE if this is the last scheduled layer.
    // -------------------------------------------------------------------------
    always_comb begin
        state_nxt     = state;
        layer_cnt_w = layer_cnt_r;
        seen_busy_w = seen_busy_r;
        config_rd_en_w = 1'b0;
        config_rd_idx_w = layer_cnt_r;

        case (state)
            IDLE: begin
                layer_cnt_w = '0;
                seen_busy_w = 1'b0;
                if (sys_start) begin
                    config_rd_en_w = 1'b1;
                    config_rd_idx_w = '0;
                    state_nxt = FETCH_CONFIG;
                end
            end

            FETCH_CONFIG: begin
                // layer_config_mem has a registered one-cycle ROM read latency.
                // The memory row requested in the previous cycle is now available.
                if (layer_valid_w && active_dev_valid_w) begin
                    state_nxt = DISPATCH;
                end else begin
                    state_nxt = DONE;
                end
            end

            DISPATCH: begin
                seen_busy_w = 1'b0;
                if (layer_valid_w && active_dev_valid_w) begin
                    state_nxt = WAIT_DEV;
                end else begin
                    state_nxt = DONE;
                end
            end

            WAIT_DEV: begin
                if (active_dev_valid_w && busy_i[active_dev_idx_w]) begin
                    seen_busy_w = 1'b1;
                end

                //active_done_w represents receive this layer is done from the devices.
                if (active_done_w) begin
                    seen_busy_w = 1'b0;
                    if (layer_last_w) begin
                        layer_cnt_w = '0;
                        state_nxt = DONE;
                    end else begin
                        layer_cnt_w = layer_cnt_r + MAX_LAYER'(1);
                        config_rd_en_w = 1'b1;
                        config_rd_idx_w = layer_cnt_r + MAX_LAYER'(1);
                        state_nxt = FETCH_CONFIG;
                    end
                end
            end

            DONE: begin
                seen_busy_w = 1'b0;
                if (!sys_start) begin
                    state_nxt = IDLE;
                end
            end

            default: begin
                state_nxt     = IDLE;
                layer_cnt_w = '0;
                seen_busy_w = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Config generation
    // Works like a program, and the layer_cnt_r is the program pointer.
    // PS:  This block drives the configuration signals consumed by the active layer
    //      device. The conv1x1 and its following postprocess are treated as one
    //      logical scheduled layer
    // -------------------------------------------------------------------------
    layer_config_mem #(
        .K_MAX(K_MAX),
        .K_ADDR_W(K_ADDR_W),
        .DATA_W(DATA_W),
        .OUT_W(OUT_W),
        .DIM_W(DIM_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .AO_ADDR_W(AO_ADDR_W),
        .WGT_ADDR_W(WGT_ADDR_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .MAX_LAYER(MAX_LAYER),
        .CONFIG_PROFILE(LAYER_CONFIG_PROFILE)
    ) u_layer_config_mem (
        .clk(clk),
        .rd_en_i(config_rd_en_w),
        .layer_cnt_i(config_rd_idx_w),
        .layer_valid_o(layer_valid_w),
        .layer_last_o(layer_last_w),
        .layer_type_o(layer_type_w),
        .k_size_o(k_size_o),
        .m_size_o(m_size_o),
        .n_size_o(n_size_o),
        .act_base_addr_o(act_base_addr_o),
        .wgt_base_addr_o(wgt_base_addr_o),
        .out_base_addr_o(out_base_addr_o),
        .residual_en_o(residual_en_o),
        .residual_base_addr_o(residual_base_addr_o),
        .ifmap_size_code_o(ifmap_size_code_o),
        .num_filter_code_o(num_filter_code_o),
        .stride_o(stride_o),
        .pad_o(pad_o),
        .pad_value_o(pad_value_o),
        .mode_o(mode_o),
        .output_zero_point_o(output_zero_point_o),
        .bias_base_o(bias_base_o),
        .requant_mult_base_o(requant_mult_base_o),
        .requant_shift_base_o(requant_shift_base_o),
        .prelu_mult_base_o(prelu_mult_base_o),
        .prelu_shift_base_o(prelu_shift_base_o),
        .residual_mult_base_o(residual_mult_base_o),
        .residual_shift_base_o(residual_shift_base_o),
        .residual_zero_point_base_o(residual_zero_point_base_o)
    );

    // -------------------------------------------------------------------------
    // Device decode
    //
    // layer_config_mem decodes layer_cnt_r into layer_type_w and the per-layer
    // configuration. This block only converts the opcode into the hardware
    // device index that should receive start_o and own the shared GB connection.
    // Current device slots:
    //   LY_CONV1X1    -> CONV1X1_DEV
    //   LY_DWCONV3X3  -> SPATIAL_DEV
    //   LY_CONV3X3    -> SPATIAL_DEV
    // -------------------------------------------------------------------------
    always_comb begin
        active_dev_valid_w = 1'b0;
        active_dev_idx_w   = '0;

        case (layer_type_w)
            LY_CONV1X1: begin
                active_dev_valid_w = 1'b1;
                active_dev_idx_w   = CONV1X1_DEV;
            end

            LY_DWCONV3X3: begin
                if (NUM_DEV > 1) begin
                    active_dev_valid_w = 1'b1;
                    active_dev_idx_w   = SPATIAL_DEV;
                end
            end

            LY_CONV3X3: begin
                if (NUM_DEV > 1) begin
                    active_dev_valid_w = 1'b1;
                    active_dev_idx_w   = SPATIAL_DEV;
                end
            end

            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // Shared global-buffer mux and output control
    //
    // While a device is active, the switcher grants the shared AO/WGT global
    // buffer ports to that device:
    //   dev_act_rd_* -> gb_act_rd_* and gb_act_rd_data_i -> dev_act_rd_data_o
    //   dev_ao_wr_*  -> gb_ao_wr_*
    //   dev_wgt_rd_* -> gb_wgt_rd_* and gb_wgt_rd_data_i -> dev_wgt_rd_data_o
    //
    // These SRAM model ports do not have ready/valid backpressure in the current
    // design. valid+addr are simply forwarded from the active device, and the
    // returned registered SRAM data is forwarded back to that same device. All
    // inactive devices see zero read data and cannot drive the shared buffers.
    // -------------------------------------------------------------------------
    always_comb begin
        //set default value
        sys_done      = (state == DONE);
        final_valid_o = (state == DONE);
        final_vec_o   = '0;

        gb_act_rd_valid_o = 1'b0;
        gb_act_rd_addr_o  = '0;
        gb_ao_wr_valid_o  = 1'b0;
        gb_ao_wr_addr_o   = '0;
        gb_ao_wr_data_o   = '0;
        gb_ao_wr_mask_o   = '0;
        gb_wgt_rd_valid_o = 1'b0;
        gb_wgt_rd_addr_o  = '0;

        for (int d = 0; d < NUM_DEV; d++) begin
            start_o[d]           = 1'b0;
            dev_act_rd_data_o[d] = '0;
            dev_wgt_rd_data_o[d] = '0;
        end
        //default set is done

        //mux the connection to SRAM
        if (active_dev_valid_w && ((state == DISPATCH) || (state == WAIT_DEV))) begin
            start_o[active_dev_idx_w] = (state == DISPATCH);    //the start_o[dev] assert one cycle here

            gb_act_rd_valid_o = dev_act_rd_valid_i[active_dev_idx_w];
            gb_act_rd_addr_o  = dev_act_rd_addr_i[active_dev_idx_w];
            dev_act_rd_data_o[active_dev_idx_w] = gb_act_rd_data_i;

            gb_ao_wr_valid_o = dev_ao_wr_valid_i[active_dev_idx_w];
            gb_ao_wr_addr_o  = dev_ao_wr_addr_i[active_dev_idx_w];
            gb_ao_wr_data_o  = dev_ao_wr_data_i[active_dev_idx_w];
            gb_ao_wr_mask_o  = dev_ao_wr_mask_i[active_dev_idx_w];

            gb_wgt_rd_valid_o = dev_wgt_rd_valid_i[active_dev_idx_w];
            gb_wgt_rd_addr_o  = dev_wgt_rd_addr_i[active_dev_idx_w];
            dev_wgt_rd_data_o[active_dev_idx_w] = gb_wgt_rd_data_i;
        end
    end

endmodule
