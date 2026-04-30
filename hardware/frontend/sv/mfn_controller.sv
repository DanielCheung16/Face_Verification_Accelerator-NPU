// ==============================================================================
// Module: mfn_controller
// Description: FSM for MobileFaceNet Frontend.
//   Supports Standard Conv and Depthwise Conv (is_dw flag).
//   Pipelined MAC (1-cycle latency), incremental weight addressing.
// ==============================================================================

module mfn_controller #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 40
)(
    input  logic              clk,
    input  logic              rst_n,
    
    // Global Control
    input  logic              start,
    output logic              done,
    
    // Config ROM Interface
    output logic [5:0]        layer_idx,
    input  logic [63:0]       layer_config,
    input  logic              layer_is_pw,
    input  logic              layer_is_res,
    
    // Addr Gen Interface
    output logic              reset_ptr,
    output logic              inc_write,
    output logic              read_res,
    output logic signed [8:0] x_out,
    output logic signed [8:0] y_out,
    output logic [9:0]        c_in_out,
    
    // Component Control
    output logic              load_pixel,
    output logic [3:0]        pixel_idx,
    output logic [19:0]       weight_addr,
    output logic              enable_mac,
    output logic              clear_mac_acc,
    input  logic [AWIDTH-1:0] mac_bias_in,
    
    // Bias/PReLU address (includes layer base offset, needs 14 bits for 48 layers)
    output logic [13:0]       bias_addr,
    
    // Accumulation Output
    input  logic [AWIDTH-1:0] mac_data_in,
    output logic [AWIDTH-1:0] psum_to_act
);

    // --------------------------------------------------------------------------
    // FSM States
    // --------------------------------------------------------------------------
    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_LOAD_CFG,
        STATE_WAIT_CFG,
        STATE_INIT_PSUM,
        STATE_FETCH_PIXELS,
        STATE_CALC_PSUM,
        STATE_MAC_FLUSH,
        STATE_MAC_FLUSH_2,
        STATE_CH_IN_LOOP,
        STATE_READ_RESIDUAL,
        STATE_ADD_RESIDUAL,
        STATE_WRITE_BACK,
        STATE_SPATIAL_LOOP,
        STATE_NEXT_LAYER,
        STATE_DONE
    } state_t;

    state_t state_reg, state_next;

    // --------------------------------------------------------------------------
    // Registers
    // --------------------------------------------------------------------------
    logic [5:0]  layer_idx_reg, layer_idx_next;
    logic [6:0]  layer_w, layer_h;
    logic [9:0]  layer_in_ch, layer_out_ch;
    logic [1:0]  layer_stride;
    logic        layer_is_dw;
    logic [19:0] layer_wgt_base;
    
    logic signed [8:0] x_reg, x_next;
    logic signed [8:0] y_reg, y_next;
    logic [9:0]        c_in_reg, c_in_next;
    logic [9:0]        c_out_reg, c_out_next;
    logic [3:0]        k_reg, k_next;

    // Global DW (linear7): is_pw=1 && is_dw=1 used as combined flag
    logic is_global_dw;
    assign is_global_dw = layer_is_pw & layer_is_dw;

    // group_idx: which of the 5 groups of 9 we are processing for global DW
    logic [2:0] group_idx_reg, group_idx_next;  // 0..4

    // Global DW kernel position decoder: maps (group_idx, k_reg) → (gdw_ky, gdw_kx)
    logic [5:0] k_global_comb;
    logic [5:0] group_base;
    logic [3:0] gdw_kx, gdw_ky;

    always_comb begin : gdw_lut
        case (group_idx_reg)
            3'd0: group_base = 6'd0;
            3'd1: group_base = 6'd9;
            3'd2: group_base = 6'd18;
            3'd3: group_base = 6'd27;
            3'd4: group_base = 6'd36;
            default: group_base = 6'd0;
        endcase
        k_global_comb = group_base + {2'b0, k_reg};
        if (k_global_comb < 6'd42) begin
            gdw_ky = k_global_comb / 4'd6;  // 0..6
            gdw_kx = k_global_comb % 4'd6;  // 0..5
        end else begin
            gdw_ky = 4'd7;  // out-of-bounds → is_pad
            gdw_kx = 4'd6;  // out-of-bounds → is_pad
        end
    end

    // Kernel offset LUT (replaces k%3 and k/3) — used for non-global-DW layers
    logic signed [1:0] kx_offset, ky_offset;
    always_comb begin
        if (is_global_dw) begin
            kx_offset = 2'sd0; ky_offset = 2'sd0;  // unused; gdw_kx/ky used instead
        end else if (layer_is_pw) begin
            kx_offset = 2'sd0; ky_offset = 2'sd0;
        end else begin
            case (k_reg)
                4'd0: begin kx_offset = -2'sd1; ky_offset = -2'sd1; end
                4'd1: begin kx_offset =  2'sd0; ky_offset = -2'sd1; end
                4'd2: begin kx_offset =  2'sd1; ky_offset = -2'sd1; end
                4'd3: begin kx_offset = -2'sd1; ky_offset =  2'sd0; end
                4'd4: begin kx_offset =  2'sd0; ky_offset =  2'sd0; end
                4'd5: begin kx_offset =  2'sd1; ky_offset =  2'sd0; end
                4'd6: begin kx_offset = -2'sd1; ky_offset =  2'sd1; end
                4'd7: begin kx_offset =  2'sd0; ky_offset =  2'sd1; end
                4'd8: begin kx_offset =  2'sd1; ky_offset =  2'sd1; end
                default: begin kx_offset = 2'sd0; ky_offset = 2'sd0; end
            endcase
        end
    end

    // Incremental weight addressing (relative within layer, 18-bit sufficient)
    logic [17:0] wgt_addr_reg, wgt_addr_next;
    logic [17:0] wgt_cin_base_reg, wgt_cin_base_next;
    logic [17:0] wgt_step_reg, wgt_step_next;

    // Bias/PReLU base per layer (accumulates out_ch per layer, needs 14 bits for 48 layers)
    logic [13:0] bias_base_reg, bias_base_next;

    // Timing alignment
    logic [3:0]  k_reg_d1;
    logic        load_pixel_comb, load_pixel_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_reg_d1      <= '0;
            load_pixel_d1 <= 1'b0;
        end else begin
            k_reg_d1      <= k_reg;
            load_pixel_d1 <= load_pixel_comb;
        end
    end

    assign pixel_idx  = k_reg_d1;
    assign load_pixel = load_pixel_d1;
    
    // MAC pipeline delay tracking (2 stages now)
    logic [9:0] c_out_d1, c_out_d2;
    logic       calc_psum_d1, calc_psum_d2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_out_d1     <= '0;
            c_out_d2     <= '0;
            calc_psum_d1 <= 1'b0;
            calc_psum_d2 <= 1'b0;
        end else begin
            c_out_d1     <= c_out_reg;
            c_out_d2     <= c_out_d1;
            calc_psum_d1 <= (state_reg == STATE_CALC_PSUM);
            calc_psum_d2 <= calc_psum_d1;
        end
    end

    // Partial Sum Register File (needs 512 entries for max 512ch output layers)
    logic signed [AWIDTH-1:0] psum_mem [0:511];

    // --------------------------------------------------------------------------
    // Config Decoding (64-bit)
    // New layout: {wr_buf(2),rd_buf(2),wgt_base(20),is_dw(1),is_pw(1),is_res(1),
    //              prelu(1),stride(2),h(7),w(7),out_ch(10),in_ch(10)}
    // --------------------------------------------------------------------------
    assign layer_in_ch    = layer_config[9:0];
    assign layer_out_ch   = layer_config[19:10];
    assign layer_w        = layer_config[26:20];
    assign layer_h        = layer_config[33:27];
    assign layer_stride   = layer_config[35:34];
    assign layer_is_dw    = layer_config[39];
    assign layer_wgt_base = layer_config[59:40];
    
    assign layer_idx      = layer_idx_reg;
    assign x_out = is_global_dw ? $signed({5'b0, gdw_kx}) :
                   (x_reg + {{7{kx_offset[1]}}, kx_offset});
    assign y_out = is_global_dw ? $signed({5'b0, gdw_ky}) :
                   (y_reg + {{7{ky_offset[1]}}, ky_offset});
    assign c_in_out       = (layer_is_dw || state_reg == STATE_READ_RESIDUAL || state_reg == STATE_WRITE_BACK) ? c_out_reg :
                            (layer_is_pw ? (c_in_reg + {6'd0, k_reg}) : c_in_reg);
    assign bias_addr      = bias_base_reg + {4'd0, c_out_reg};
    assign read_res       = (state_reg == STATE_READ_RESIDUAL);

    // --------------------------------------------------------------------------
    // Next State & Output Logic
    // --------------------------------------------------------------------------
    always_comb begin
        state_next        = state_reg;
        layer_idx_next    = layer_idx_reg;
        x_next            = x_reg;
        y_next            = y_reg;
        c_in_next         = c_in_reg;
        c_out_next        = c_out_reg;
        k_next            = k_reg;
        wgt_addr_next     = wgt_addr_reg;
        wgt_cin_base_next = wgt_cin_base_reg;
        wgt_step_next     = wgt_step_reg;
        bias_base_next    = bias_base_reg;
        
        group_idx_next  = group_idx_reg;
        reset_ptr       = 1'b0;
        inc_write       = 1'b0;
        load_pixel_comb = 1'b0;
        enable_mac      = 1'b0;
        clear_mac_acc   = 1'b0;
        weight_addr     = '0;
        done            = 1'b0;
        
        case (state_reg)
            STATE_IDLE: begin
                if (start) state_next = STATE_LOAD_CFG;
            end
            
            STATE_LOAD_CFG: begin
                state_next = STATE_WAIT_CFG;
                x_next = '0; y_next = '0; c_in_next = '0; c_out_next = '0;
            end

            STATE_WAIT_CFG: begin
                // Precompute wgt_step
                if (layer_is_dw)
                    wgt_step_next = 18'd9;   // DW: only 9 weights per channel
                else if (layer_is_pw) begin
                    // step = ceil(in_ch/9)*9 (packed weight groups per output channel)
                    case (layer_in_ch)
                        10'd64:  wgt_step_next = 18'd72;   // ceil(64/9)=8,  8*9=72
                        10'd128: wgt_step_next = 18'd135;  // ceil(128/9)=15, 15*9=135
                        10'd256: wgt_step_next = 18'd261;  // ceil(256/9)=29, 29*9=261
                        10'd512: wgt_step_next = 18'd513;  // ceil(512/9)=57, 57*9=513
                        default: wgt_step_next = 18'd72;
                    endcase
                end
                else
                    wgt_step_next = {layer_in_ch, 3'b0} + {8'b0, layer_in_ch}; // in_ch*9
                wgt_cin_base_next = '0;
                state_next = STATE_INIT_PSUM;
            end

            STATE_INIT_PSUM: begin
                if (layer_is_dw) begin
                    // DW: init only psum[0] for current channel, go straight to FETCH
                    c_out_next = c_out_reg;  // keep current channel
                    state_next = STATE_FETCH_PIXELS;
                end else begin
                    // Standard: init all out_ch psum entries
                    if (c_out_reg == layer_out_ch - 1) begin
                        c_out_next = '0;
                        state_next = STATE_FETCH_PIXELS;
                    end else begin
                        c_out_next = c_out_reg + 1'b1;
                    end
                end
            end

            STATE_FETCH_PIXELS: begin
                if (layer_is_pw) begin
                    // Pointwise / Global-DW: Fetch 9 pixels over 9 cycles
                    if (k_reg < 4'd9) begin
                        load_pixel_comb = 1'b1;
                        k_next = k_reg + 1'b1;
                    end else begin
                        load_pixel_comb = 1'b0;
                        k_next = '0;
                        // For global DW groups > 0 keep wgt_addr where CALC_PSUM left it
                        if (!is_global_dw || group_idx_reg == 3'd0)
                            wgt_addr_next = wgt_cin_base_reg;
                        state_next = STATE_CALC_PSUM;
                    end
                end else begin
                    // Standard/Depthwise: Fetch 3x3 window (9 pixels)
                    if (k_reg < 4'd9) begin
                        load_pixel_comb = 1'b1;
                        k_next = k_reg + 1'b1;
                    end else begin
                        load_pixel_comb = 1'b0;
                        k_next = '0;
                        wgt_addr_next = wgt_cin_base_reg;
                        state_next = STATE_CALC_PSUM;
                    end
                end
            end
            
            STATE_CALC_PSUM: begin
                enable_mac  = 1'b1;
                weight_addr = layer_wgt_base + {2'b0, wgt_addr_reg};
                wgt_addr_next = wgt_addr_reg + wgt_step_reg;

                if (is_global_dw) begin
                    // Global DW: 5 groups of 9 before flushing
                    if (group_idx_reg == 3'd4) begin
                        group_idx_next = '0;
                        state_next = STATE_MAC_FLUSH;
                    end else begin
                        group_idx_next = group_idx_reg + 1'b1;
                        state_next = STATE_FETCH_PIXELS;
                    end
                end else if (layer_is_dw) begin
                    // Regular DW: single MAC per channel
                    state_next = STATE_MAC_FLUSH;
                end else begin
                    // Standard/PW: iterate all out_ch
                    if (c_out_reg == layer_out_ch - 1) begin
                        c_out_next = '0;
                        state_next = STATE_MAC_FLUSH;
                    end else begin
                        c_out_next = c_out_reg + 1'b1;
                    end
                end
            end

            STATE_MAC_FLUSH: begin
                state_next = STATE_MAC_FLUSH_2;
            end
            
            STATE_MAC_FLUSH_2: begin
                if (layer_is_dw)
                    state_next = STATE_WRITE_BACK;  // DW: skip CH_IN_LOOP
                else
                    state_next = STATE_CH_IN_LOOP;
            end
            
            STATE_CH_IN_LOOP: begin
                // Only reached in standard/PW conv mode
                if (layer_is_pw) begin
                    if (c_in_reg + 10'd9 >= layer_in_ch) begin
                        c_in_next  = '0;
                        state_next = STATE_WRITE_BACK;
                    end else begin
                        c_in_next  = c_in_reg + 10'd9;
                        wgt_cin_base_next = wgt_cin_base_reg + 18'd9; // +9 weight lines
                        state_next = STATE_FETCH_PIXELS;
                    end
                end else begin
                    if (c_in_reg == layer_in_ch - 1) begin
                        c_in_next  = '0;
                        state_next = STATE_WRITE_BACK;
                    end else begin
                        c_in_next = c_in_reg + 1'b1;
                        wgt_cin_base_next = wgt_cin_base_reg + 18'd9;
                        state_next = STATE_FETCH_PIXELS;
                    end
                end
            end
            
            STATE_WRITE_BACK: begin
                if (layer_is_res) begin
                    // Before writing, read the residual
                    state_next = STATE_READ_RESIDUAL;
                end else begin
                    inc_write = 1'b1;
                    if (layer_is_dw) begin
                        if (c_out_reg == layer_out_ch - 1) begin
                            c_out_next = '0;
                            state_next = STATE_SPATIAL_LOOP;
                        end else begin
                            c_out_next = c_out_reg + 1'b1;
                            wgt_cin_base_next = wgt_cin_base_reg +
                                (is_global_dw ? 18'd45 : 18'd9);
                            state_next = STATE_INIT_PSUM;
                        end
                    end else begin
                        if (c_out_reg == layer_out_ch - 1) begin
                            c_out_next = '0;
                            state_next = STATE_SPATIAL_LOOP;
                        end else begin
                            c_out_next = c_out_reg + 1'b1;
                        end
                    end
                end
            end
            
            STATE_READ_RESIDUAL: begin
                state_next = STATE_ADD_RESIDUAL;
            end
            
            STATE_ADD_RESIDUAL: begin
                inc_write = 1'b1;
                if (layer_is_dw) begin
                    if (c_out_reg == layer_out_ch - 1) begin
                        c_out_next = '0;
                        state_next = STATE_SPATIAL_LOOP;
                    end else begin
                        c_out_next = c_out_reg + 1'b1;
                        wgt_cin_base_next = wgt_cin_base_reg +
                            (is_global_dw ? 18'd45 : 18'd9);
                        state_next = STATE_INIT_PSUM;
                    end
                end else begin
                    if (c_out_reg == layer_out_ch - 1) begin
                        c_out_next = '0;
                        state_next = STATE_SPATIAL_LOOP;
                    end else begin
                        c_out_next = c_out_reg + 1'b1;
                        state_next = STATE_READ_RESIDUAL;
                    end
                end
            end
            
            STATE_SPATIAL_LOOP: begin
                wgt_cin_base_next = '0;
                if (is_global_dw) begin
                    // 1×1 output: no spatial loop needed
                    state_next = STATE_NEXT_LAYER;
                end else if (x_reg >= (layer_w - layer_stride)) begin
                    x_next = '0;
                    if (y_reg >= (layer_h - layer_stride)) begin
                        y_next     = '0;
                        state_next = STATE_NEXT_LAYER;
                    end else begin
                        y_next     = y_reg + layer_stride;
                        state_next = STATE_INIT_PSUM;
                    end
                end else begin
                    x_next     = x_reg + layer_stride;
                    state_next = STATE_INIT_PSUM;
                end
            end

            STATE_NEXT_LAYER: begin
                if (layer_idx_reg >= 6'd49) begin  // Stop after Layer 49 (linear1)
                    state_next = STATE_DONE;
                end else begin
                    // Accumulate bias base for next layer
                    bias_base_next = bias_base_reg + layer_out_ch;
                    layer_idx_next = layer_idx_reg + 1'b1;
                    state_next     = STATE_LOAD_CFG;
                    reset_ptr      = 1'b1;
                end
            end
            
            STATE_DONE: begin
                done = 1'b1;
                state_next = STATE_IDLE;
            end
        endcase
    end

    // --------------------------------------------------------------------------
    // Partial Sum Management
    // --------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (state_reg == STATE_INIT_PSUM) begin
            if (layer_is_dw)
                psum_mem[0] <= mac_bias_in;          // DW: always index 0
            else
                psum_mem[c_out_reg] <= mac_bias_in;  // Standard: per c_out
        end else if (calc_psum_d2) begin
            if (layer_is_dw)
                psum_mem[0] <= psum_mem[0] + mac_data_in;
            else
                psum_mem[c_out_d2] <= psum_mem[c_out_d2] + mac_data_in;
        end
    end
    
    // Residual Addition happens externally? No, psum_to_act is output to mfn_activation.
    // mfn_activation clamps it. But residual addition happens after PW2!
    // Wait, mfn_activation needs to add residual.
    assign psum_to_act = layer_is_dw ? psum_mem[0] : psum_mem[c_out_reg];

    // --------------------------------------------------------------------------
    // Sequential Logic
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg        <= STATE_IDLE;
            layer_idx_reg    <= '0;
            x_reg <= '0; y_reg <= '0; c_in_reg <= '0; c_out_reg <= '0; k_reg <= '0;
            wgt_addr_reg     <= '0;
            wgt_cin_base_reg <= '0;
            wgt_step_reg     <= '0;
            bias_base_reg    <= 14'd0;
            group_idx_reg    <= '0;
        end else begin
            state_reg        <= state_next;
            layer_idx_reg    <= layer_idx_next;
            x_reg            <= x_next;
            y_reg            <= y_next;
            c_in_reg         <= c_in_next;
            c_out_reg        <= c_out_next;
            k_reg            <= k_next;
            wgt_addr_reg     <= wgt_addr_next;
            wgt_cin_base_reg <= wgt_cin_base_next;
            wgt_step_reg     <= wgt_step_next;
            bias_base_reg    <= bias_base_next;
            group_idx_reg    <= group_idx_next;
        end
    end

endmodule
