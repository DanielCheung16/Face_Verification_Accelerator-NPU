// ==============================================================================
// Module: mfn_controller (v2)
// v2 changes over v1:
//   Item 3 — Wide SRAM fetch: standard/DW conv FETCH takes 3 cycles (k=0,1,2)
//            instead of 11. addr_gen outputs all 9 addrs simultaneously.
//   Item 4 — CLA psum adder: 40-bit 2-level CLA replaces ripple-carry on
//            psum_mem accumulation, reducing critical path from O(N) to O(log N).
//   Item 5 — Dual c_out MAC: in CALC_PSUM (!layer_is_dw), process c_out and
//            c_out+1 in parallel using two MAC arrays → halves CALC_PSUM cycles.
// ==============================================================================

module mfn_controller #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 40
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic              start,
    output logic              done,

    output logic [5:0]        layer_idx,
    input  logic [63:0]       layer_config,
    input  logic              layer_is_pw,
    input  logic              layer_is_res,

    output logic              reset_ptr,
    output logic              inc_write,
    output logic              read_res,
    output logic signed [8:0] x_out,
    output logic signed [8:0] y_out,
    output logic [9:0]        c_in_out,

    // Single-pixel load (PW / global-DW path unchanged)
    output logic              load_pixel,
    output logic [3:0]        pixel_idx,

    // v2: wide-mode signals
    output logic              wide_mode,     // → addr_gen: compute 9 addrs from center
    output logic              wide_load_en,  // → sliding_window: latch all 9 pixels

    output logic [19:0]       weight_addr,
    output logic [19:0]       weight_addr_b, // v2: second MAC weight address
    output logic              enable_mac,
    output logic              enable_mac_b,  // v2: second MAC enable
    output logic              clear_mac_acc,
    input  logic [AWIDTH-1:0] mac_bias_in,

    output logic [13:0]       bias_addr,

    input  logic [AWIDTH-1:0] mac_data_in,
    input  logic [AWIDTH-1:0] mac_data_in_b, // v2: second MAC result
    output logic [AWIDTH-1:0] psum_to_act
);

    // --------------------------------------------------------------------------
    // FSM States (identical to v1)
    // --------------------------------------------------------------------------
    typedef enum logic [4:0] {
        STATE_IDLE, STATE_LOAD_CFG, STATE_WAIT_CFG, STATE_INIT_PSUM,
        STATE_FETCH_PIXELS, STATE_CALC_PSUM, STATE_MAC_FLUSH, STATE_MAC_FLUSH_2,
        STATE_CH_IN_LOOP, STATE_READ_RESIDUAL, STATE_READ_RESIDUAL_WAIT,
        STATE_ADD_RESIDUAL, STATE_WRITE_BACK, STATE_SPATIAL_LOOP,
        STATE_NEXT_LAYER_WAIT, STATE_NEXT_LAYER, STATE_DONE
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
    logic [9:0]        c_in_reg,  c_in_next;
    logic [9:0]        c_out_reg, c_out_next;
    logic [3:0]        k_reg,     k_next;

    logic is_global_dw;
    assign is_global_dw = layer_is_pw & layer_is_dw;

    logic [2:0] group_idx_reg, group_idx_next;

    logic [5:0] k_global_comb, group_base;
    logic [3:0] gdw_kx, gdw_ky;

    always_comb begin : gdw_lut
        case (group_idx_reg)
            3'd0: group_base = 6'd0;  3'd1: group_base = 6'd9;
            3'd2: group_base = 6'd18; 3'd3: group_base = 6'd27;
            3'd4: group_base = 6'd36; default: group_base = 6'd0;
        endcase
        k_global_comb = group_base + {2'b0, k_reg};
        if (k_global_comb < 6'd42) begin
            gdw_ky = k_global_comb / 4'd6;
            gdw_kx = k_global_comb % 4'd6;
        end else begin
            gdw_ky = 4'd7; gdw_kx = 4'd6;
        end
    end

    logic signed [1:0] kx_offset, ky_offset;
    always_comb begin
        if (is_global_dw)  begin kx_offset = 2'sd0; ky_offset = 2'sd0; end
        else if (layer_is_pw) begin kx_offset = 2'sd0; ky_offset = 2'sd0; end
        else begin
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

    logic [17:0] wgt_addr_reg, wgt_addr_next;
    logic [17:0] wgt_cin_base_reg, wgt_cin_base_next;
    logic [17:0] wgt_step_reg, wgt_step_next;
    logic [13:0] bias_base_reg, bias_base_next;

    // --------------------------------------------------------------------------
    // Single-pixel load pipeline (PW / global-DW path)
    // --------------------------------------------------------------------------
    logic [3:0]  k_reg_d1, k_reg_d2;
    logic        load_pixel_comb, load_pixel_d1, load_pixel_d2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_reg_d1 <= '0; k_reg_d2 <= '0;
            load_pixel_d1 <= 1'b0; load_pixel_d2 <= 1'b0;
        end else begin
            k_reg_d1      <= k_reg;
            k_reg_d2      <= k_reg_d1;
            load_pixel_d1 <= load_pixel_comb;
            load_pixel_d2 <= load_pixel_d1;
        end
    end
    assign pixel_idx  = k_reg_d2;
    assign load_pixel = load_pixel_d2;

    // --------------------------------------------------------------------------
    // MAC pipeline delay tracking
    // --------------------------------------------------------------------------
    logic [9:0] c_out_d1, c_out_d2;
    logic       calc_psum_d1, calc_psum_d2;
    logic       enable_mac_b_comb;   // combinational, pipelined below
    logic       enable_mac_b_d1, enable_mac_b_d2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_out_d1       <= '0; c_out_d2       <= '0;
            calc_psum_d1   <= 1'b0; calc_psum_d2  <= 1'b0;
            enable_mac_b_d1 <= 1'b0; enable_mac_b_d2 <= 1'b0;
        end else begin
            c_out_d1       <= c_out_reg;
            c_out_d2       <= c_out_d1;
            calc_psum_d1   <= (state_reg == STATE_CALC_PSUM);
            calc_psum_d2   <= calc_psum_d1;
            enable_mac_b_d1 <= enable_mac_b_comb;
            enable_mac_b_d2 <= enable_mac_b_d1;
        end
    end

    // --------------------------------------------------------------------------
    // Partial Sum Register File
    // --------------------------------------------------------------------------
    logic signed [AWIDTH-1:0] psum_mem [0:511];

    // CLA adder outputs (Item 4)
    logic [AWIDTH-1:0] cla_sum_a, cla_sum_b;

    mfn_cla40 u_cla_a (
        .a(psum_mem[c_out_d2]),
        .b(mac_data_in),
        .sum(cla_sum_a)
    );

    mfn_cla40 u_cla_b (
        .a(psum_mem[c_out_d2 + 1]),
        .b(mac_data_in_b),
        .sum(cla_sum_b)
    );

    // --------------------------------------------------------------------------
    // Config Decoding
    // --------------------------------------------------------------------------
    assign layer_in_ch    = layer_config[9:0];
    assign layer_out_ch   = layer_config[19:10];
    assign layer_w        = layer_config[26:20];
    assign layer_h        = layer_config[33:27];
    assign layer_stride   = layer_config[35:34];
    assign layer_is_dw    = layer_config[39];
    assign layer_wgt_base = layer_config[59:40];
    assign layer_idx      = layer_idx_reg;

    // x_out/y_out: use center (no offset) in wide mode, else existing logic
    assign x_out = wide_mode ? x_reg :
                   (is_global_dw ? $signed({5'b0, gdw_kx}) :
                   (x_reg + {{7{kx_offset[1]}}, kx_offset}));
    assign y_out = wide_mode ? y_reg :
                   (is_global_dw ? $signed({5'b0, gdw_ky}) :
                   (y_reg + {{7{ky_offset[1]}}, ky_offset}));

    assign c_in_out = (layer_is_dw || state_reg == STATE_READ_RESIDUAL
                      || state_reg == STATE_READ_RESIDUAL_WAIT
                      || state_reg == STATE_WRITE_BACK) ? c_out_reg :
                      (layer_is_pw ? (c_in_reg + {6'd0, k_reg}) : c_in_reg);
    assign bias_addr = bias_base_reg + {4'd0, c_out_reg};
    assign read_res  = (state_reg == STATE_READ_RESIDUAL)
                     || (state_reg == STATE_READ_RESIDUAL_WAIT);

    // --------------------------------------------------------------------------
    // Next State & Output Logic
    // --------------------------------------------------------------------------
    always_comb begin
        state_next        = state_reg;
        layer_idx_next    = layer_idx_reg;
        x_next            = x_reg; y_next = y_reg;
        c_in_next         = c_in_reg; c_out_next = c_out_reg;
        k_next            = k_reg;
        wgt_addr_next     = wgt_addr_reg;
        wgt_cin_base_next = wgt_cin_base_reg;
        wgt_step_next     = wgt_step_reg;
        bias_base_next    = bias_base_reg;
        group_idx_next    = group_idx_reg;

        reset_ptr        = 1'b0;
        inc_write        = 1'b0;
        load_pixel_comb  = 1'b0;
        enable_mac       = 1'b0;
        enable_mac_b_comb = 1'b0;
        clear_mac_acc    = 1'b0;
        weight_addr      = '0;
        weight_addr_b    = '0;
        wide_mode        = 1'b0;
        wide_load_en     = 1'b0;
        done             = 1'b0;

        case (state_reg)
            STATE_IDLE: begin
                if (start) state_next = STATE_LOAD_CFG;
            end

            STATE_LOAD_CFG: begin
                state_next = STATE_WAIT_CFG;
                x_next = '0; y_next = '0; c_in_next = '0; c_out_next = '0;
            end

            STATE_WAIT_CFG: begin
                if (layer_is_dw)
                    wgt_step_next = 18'd9;
                else if (layer_is_pw) begin
                    case (layer_in_ch)
                        10'd64:  wgt_step_next = 18'd72;
                        10'd128: wgt_step_next = 18'd135;
                        10'd256: wgt_step_next = 18'd261;
                        10'd512: wgt_step_next = 18'd513;
                        default: wgt_step_next = 18'd72;
                    endcase
                end else
                    wgt_step_next = {layer_in_ch, 3'b0} + {8'b0, layer_in_ch};
                wgt_cin_base_next = '0;
                state_next = STATE_INIT_PSUM;
            end

            STATE_INIT_PSUM: begin
                if (layer_is_dw) begin
                    c_out_next = c_out_reg;
                    state_next = STATE_FETCH_PIXELS;
                end else begin
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
                    // ── PW / Global-DW: sequential single-pixel fetch (unchanged) ──
                    if (k_reg < 4'd9) begin
                        load_pixel_comb = 1'b1;
                        k_next = k_reg + 1'b1;
                    end else if (k_reg == 4'd9) begin
                        load_pixel_comb = 1'b0;
                        k_next = k_reg + 1'b1;
                        if (!is_global_dw || group_idx_reg == 3'd0)
                            wgt_addr_next = wgt_cin_base_reg;
                    end else begin
                        load_pixel_comb = 1'b0;
                        k_next = '0;
                        state_next = STATE_CALC_PSUM;
                    end
                end else begin
                    // ── Standard/DW: wide-mode fetch (Item 3) ──────────────────
                    // k=0: present center coords; addr_gen Stage1 captures next cycle
                    // k=1: Stage2 outputs 9 addrs; SRAM reads
                    // k=2: SRAM data valid; load all 9 into window; → CALC_PSUM
                    wide_mode = (k_reg <= 4'd1);
                    case (k_reg)
                        4'd0: k_next = 4'd1;
                        4'd1: k_next = 4'd2;
                        default: begin  // k=2
                            wide_load_en  = 1'b1;
                            wgt_addr_next = wgt_cin_base_reg;
                            k_next        = '0;
                            state_next    = STATE_CALC_PSUM;
                        end
                    endcase
                end
            end

            STATE_CALC_PSUM: begin
                if (is_global_dw) begin
                    enable_mac  = 1'b1;
                    weight_addr = layer_wgt_base + {2'b0, wgt_addr_reg};
                    wgt_addr_next = wgt_addr_reg + wgt_step_reg;
                    if (group_idx_reg == 3'd4) begin
                        group_idx_next = '0;
                        state_next = STATE_MAC_FLUSH;
                    end else begin
                        group_idx_next = group_idx_reg + 1'b1;
                        state_next = STATE_FETCH_PIXELS;
                    end
                end else if (layer_is_dw) begin
                    enable_mac  = 1'b1;
                    weight_addr = layer_wgt_base + {2'b0, wgt_addr_reg};
                    wgt_addr_next = wgt_addr_reg + wgt_step_reg;
                    state_next = STATE_MAC_FLUSH;
                end else begin
                    // ── Dual MAC for standard/PW (Item 5) ────────────────────
                    enable_mac       = 1'b1;
                    enable_mac_b_comb = (c_out_reg + 1 < layer_out_ch);
                    weight_addr      = layer_wgt_base + {2'b0, wgt_addr_reg};
                    weight_addr_b    = layer_wgt_base + {2'b0, wgt_addr_reg}
                                       + {2'b0, wgt_step_reg};
                    wgt_addr_next    = wgt_addr_reg + wgt_step_reg + wgt_step_reg;

                    if (c_out_reg + 10'd2 >= layer_out_ch) begin
                        c_out_next = '0;
                        state_next = STATE_MAC_FLUSH;
                    end else begin
                        c_out_next = c_out_reg + 10'd2;
                    end
                end
            end

            STATE_MAC_FLUSH:   state_next = STATE_MAC_FLUSH_2;

            STATE_MAC_FLUSH_2: begin
                if (layer_is_dw) state_next = STATE_WRITE_BACK;
                else             state_next = STATE_CH_IN_LOOP;
            end

            STATE_CH_IN_LOOP: begin
                if (layer_is_pw) begin
                    if (c_in_reg + 10'd9 >= layer_in_ch) begin
                        c_in_next  = '0;
                        state_next = STATE_WRITE_BACK;
                    end else begin
                        c_in_next         = c_in_reg + 10'd9;
                        wgt_cin_base_next = wgt_cin_base_reg + 18'd9;
                        state_next        = STATE_FETCH_PIXELS;
                    end
                end else begin
                    if (c_in_reg == layer_in_ch - 1) begin
                        c_in_next  = '0;
                        state_next = STATE_WRITE_BACK;
                    end else begin
                        c_in_next         = c_in_reg + 1'b1;
                        wgt_cin_base_next = wgt_cin_base_reg + 18'd9;
                        state_next        = STATE_FETCH_PIXELS;
                    end
                end
            end

            STATE_WRITE_BACK: begin
                if (layer_is_res) begin
                    state_next = STATE_READ_RESIDUAL;
                end else begin
                    inc_write = 1'b1;
                    if (layer_is_dw) begin
                        if (c_out_reg == layer_out_ch - 1) begin
                            c_out_next = '0; state_next = STATE_SPATIAL_LOOP;
                        end else begin
                            c_out_next = c_out_reg + 1'b1;
                            wgt_cin_base_next = wgt_cin_base_reg +
                                (is_global_dw ? 18'd45 : 18'd9);
                            state_next = STATE_INIT_PSUM;
                        end
                    end else begin
                        if (c_out_reg == layer_out_ch - 1) begin
                            c_out_next = '0; state_next = STATE_SPATIAL_LOOP;
                        end else begin
                            c_out_next = c_out_reg + 1'b1;
                        end
                    end
                end
            end

            STATE_READ_RESIDUAL:      state_next = STATE_READ_RESIDUAL_WAIT;
            STATE_READ_RESIDUAL_WAIT: state_next = STATE_ADD_RESIDUAL;

            STATE_ADD_RESIDUAL: begin
                inc_write = 1'b1;
                if (layer_is_dw) begin
                    if (c_out_reg == layer_out_ch - 1) begin
                        c_out_next = '0; state_next = STATE_SPATIAL_LOOP;
                    end else begin
                        c_out_next = c_out_reg + 1'b1;
                        wgt_cin_base_next = wgt_cin_base_reg +
                            (is_global_dw ? 18'd45 : 18'd9);
                        state_next = STATE_INIT_PSUM;
                    end
                end else begin
                    if (c_out_reg == layer_out_ch - 1) begin
                        c_out_next = '0; state_next = STATE_SPATIAL_LOOP;
                    end else begin
                        c_out_next = c_out_reg + 1'b1;
                        state_next = STATE_READ_RESIDUAL;
                    end
                end
            end

            STATE_SPATIAL_LOOP: begin
                wgt_cin_base_next = '0;
                if (is_global_dw) begin
                    state_next = STATE_NEXT_LAYER_WAIT;
                end else if (x_reg >= (layer_w - layer_stride)) begin
                    x_next = '0;
                    if (y_reg >= (layer_h - layer_stride)) begin
                        y_next = '0; state_next = STATE_NEXT_LAYER_WAIT;
                    end else begin
                        y_next = y_reg + layer_stride;
                        state_next = STATE_INIT_PSUM;
                    end
                end else begin
                    x_next = x_reg + layer_stride;
                    state_next = STATE_INIT_PSUM;
                end
            end

            STATE_NEXT_LAYER_WAIT: state_next = STATE_NEXT_LAYER;

            STATE_NEXT_LAYER: begin
                if (layer_idx_reg >= 6'd49) begin
                    state_next = STATE_DONE;
                end else begin
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
    // Partial Sum Management (Item 4: CLA replaces + operator)
    // --------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (state_reg == STATE_INIT_PSUM) begin
            if (layer_is_dw)
                psum_mem[0] <= mac_bias_in;
            else
                psum_mem[c_out_reg] <= mac_bias_in;
        end else if (calc_psum_d2) begin
            if (layer_is_dw) begin
                psum_mem[0] <= cla_sum_a;         // DW: single channel
            end else begin
                psum_mem[c_out_d2] <= cla_sum_a;  // standard: primary c_out
                if (enable_mac_b_d2)              // Item 5: second c_out if valid
                    psum_mem[c_out_d2 + 1] <= cla_sum_b;
            end
        end
    end

    assign psum_to_act = layer_is_dw ? psum_mem[0] : psum_mem[c_out_reg];

    // Drive top-level enable_mac_b from comb
    assign enable_mac_b = enable_mac_b_comb;

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
            x_reg            <= x_next;   y_reg  <= y_next;
            c_in_reg         <= c_in_next; c_out_reg <= c_out_next;
            k_reg            <= k_next;
            wgt_addr_reg     <= wgt_addr_next;
            wgt_cin_base_reg <= wgt_cin_base_next;
            wgt_step_reg     <= wgt_step_next;
            bias_base_reg    <= bias_base_next;
            group_idx_reg    <= group_idx_next;
        end
    end

endmodule
