module layer_switcher #(
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
    parameter int GB_DATA_W = 128,
    parameter int AO_DEPTH  = 8192,
    parameter int WGT_DEPTH = 8192,
    parameter int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH),
    parameter int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH),
    parameter int NUM_DEV = 1,
    parameter int MAX_LAYER = 8,
    parameter int LAYER_TYPE_W = 3,

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

    output logic [1:0]                    mode_o,
    output logic signed [ACC_W-1:0]       bias_o       [COL],
    output logic signed [MULT_W-1:0]      multiplier_o [COL],
    output logic [SHIFT_W-1:0]            shift_o      [COL],
    output logic signed [OUT_W-1:0]       zero_point_o [COL],
    output logic signed [MULT_W-1:0]      prelu_multiplier_o [COL],
    output logic [SHIFT_W-1:0]            prelu_shift_o      [COL],

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
    localparam int NUM_SCHEDULED_LAYERS = 2;    //here to set how many layers we have 
    localparam int DEV_IDX_W = (NUM_DEV <= 1) ? 1 : $clog2(NUM_DEV);
    localparam int K_SIZE_W = K_ADDR_W + 1;

    localparam logic [1:0] MODE_REQUANT  = 2'd0;
    localparam logic [1:0] MODE_PRELU    = 2'd1;
    localparam logic [1:0] MODE_RESIDUAL = 2'd2;

    //set the activation input and output size
    localparam int IMG_28_M = 28 * 28;
    localparam int L0_K = 128;
    localparam int L0_N = 64;
    localparam int L1_K = 64;
    localparam int L1_N = 128;
    localparam int L0_WGT_WORDS = L0_K * ((L0_N + GB_LANES - 1) / GB_LANES);

    //set the base address for sram
    localparam logic [GB_ADDR_W-1:0] AO_IN_BASE  = '0;
    localparam logic [GB_ADDR_W-1:0] AO_OUT_BASE = {1'b1, {(GB_ADDR_W-1){1'b0}}};
    localparam logic [GB_ADDR_W-1:0] WGT0_BASE   = '0;
    localparam logic [GB_ADDR_W-1:0] WGT1_BASE   = GB_ADDR_W'(L0_WGT_WORDS);
    localparam logic [DEV_IDX_W-1:0] CONV1X1_DEV = '0;

    typedef enum logic [LAYER_TYPE_W-1:0] {
        LY_NOP,
        LY_CONV1X1_R,
        LY_CONV1X1_PRELU
        
    } layer_type_t;

    typedef enum logic [1:0] {
        IDLE,
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
    logic last_layer_w;
    logic active_done_w;

    assign last_layer_w = (layer_cnt_r == MAX_LAYER'(NUM_SCHEDULED_LAYERS - 1));
    assign active_done_w = active_dev_valid_w && seen_busy_r && done_i[active_dev_idx_w];

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

        case (state)
            IDLE: begin
                layer_cnt_w = '0;
                seen_busy_w = 1'b0;
                if (sys_start) begin
                    state_nxt = DISPATCH;
                end
            end

            DISPATCH: begin
                seen_busy_w = 1'b0;
                state_nxt = WAIT_DEV;
            end

            WAIT_DEV: begin
                if (active_dev_valid_w && busy_i[active_dev_idx_w]) begin
                    seen_busy_w = 1'b1;
                end

                //active_done_w represents receive this layer is done from the devices.
                if (active_done_w) begin
                    seen_busy_w = 1'b0;
                    if (last_layer_w) begin
                        layer_cnt_w = '0;
                        state_nxt = DONE;
                    end else begin
                        layer_cnt_w = layer_cnt_r + MAX_LAYER'(1);
                        state_nxt = DISPATCH;
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
    // Layer table / layer type decode
    //
    // This is the first decode stage from the pseudo-code idea:
    // layer_cnt_r is the program counter of the scheduled network slice, and
    // layer_type_w is the opcode. Today both scheduled entries are conv1x1
    // blocks, but later rows can decode to LY_DWCONV3X3, LY_POOL, LY_FC, etc.
    // -------------------------------------------------------------------------
    always_comb begin
        layer_type_w = LY_NOP;

        case (layer_cnt_r)
            MAX_LAYER'(0): layer_type_w = LY_CONV1X1_R;
            MAX_LAYER'(1): layer_type_w = LY_CONV1X1_PRELU;
            default:      layer_type_w = LY_NOP;
        endcase
    end

    // -------------------------------------------------------------------------
    // Device decode
    //
    // Convert layer_type_w into the hardware device index that should receive
    // start_o and own the shared global-buffer connection. At this stage only
    // conv1x1 exists, so every active layer maps to CONV1X1_DEV.
    // -------------------------------------------------------------------------
    always_comb begin
        active_dev_valid_w = 1'b0;
        active_dev_idx_w   = '0;

        case (layer_type_w)
            LY_CONV1X1_R, LY_CONV1X1_PRELU: begin
                active_dev_valid_w = 1'b1;
                active_dev_idx_w   = CONV1X1_DEV;
            end

            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // Config generation
    //
    // This block drives the configuration signals consumed by the active layer
    // device. The conv1x1 and its following postprocess are treated as one
    // logical scheduled layer, so mode_o and quant/PReLU parameters are emitted
    // together with k/m/n/base addresses.
    //
    // Current programmed slice from mobilefacenet_hw_simplified.csv:
    //   layer_cnt 0: rows 20 + 22, conv1x1 28x28 128->64, residual add quant
    //   layer_cnt 1: rows 23 + 25, conv1x1 28x28 64->128, PReLU quant
    //
    // Address convention for the temporary two-layer test path:
    //   AO low half  : input activation
    //   AO high half : previous conv output / next conv input
    //   WGT0_BASE    : first conv weights
    //   WGT1_BASE    : second conv weights, packed after layer 0 weights
    // -------------------------------------------------------------------------
    always_comb begin
        //set default value
        k_size_o        = '0;
        m_size_o        = '0;
        n_size_o        = '0;
        act_base_addr_o = '0;
        wgt_base_addr_o = '0;
        mode_o          = MODE_REQUANT;

        for (int c = 0; c < COL; c++) begin
            bias_o[c]              = '0;
            multiplier_o[c]        = MULT_W'(1);
            shift_o[c]             = '0;
            zero_point_o[c]        = '0;
            prelu_multiplier_o[c]  = MULT_W'(1);
            prelu_shift_o[c]       = '0;
        end
        //default set is done

        // mobilefacenet_hw_simplified.csv rows 20 + 22:
        //   conv_3.model.0.0.project.conv, 28x28, 128 -> 64
        //   conv_3.model.0.1, residual_add_output_quant
        //
        // rows 23 + 25:
        //   conv_3.model.1.0.conv.conv, 28x28, 64 -> 128
        //   conv_3.model.1.0.conv.prelu, prelu_then_activation_quant
        case (layer_type_w)
            LY_CONV1X1_R: begin
                k_size_o        = K_SIZE_W'(L0_K);
                m_size_o        = DIM_W'(IMG_28_M);
                n_size_o        = DIM_W'(L0_N);
                act_base_addr_o = AO_IN_BASE;
                wgt_base_addr_o = WGT0_BASE;
                mode_o          = MODE_RESIDUAL;
            end

            LY_CONV1X1_PRELU: begin
                k_size_o        = K_SIZE_W'(L1_K);
                m_size_o        = DIM_W'(IMG_28_M);
                n_size_o        = DIM_W'(L1_N);
                act_base_addr_o = AO_OUT_BASE;
                wgt_base_addr_o = WGT1_BASE;
                mode_o          = MODE_PRELU;
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
