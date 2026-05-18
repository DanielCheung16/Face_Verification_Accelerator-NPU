// =============================================================================
// mfn_controller_v3.sv — Tiled SA Controller for MobileFaceNet v3
//
// Key differences from v2 controller:
//   1. PW conv  → output-stationary 12×12 SA tiles (c_out × c_in)
//   2. DW conv  → 12-channel parallel (12 SA rows, opt ①)
//   3. Standard 3×3 → SA with in_ch=3 (falls through PW path after sliding window)
//   4. Activation buffer (mfn_act_buf) pre-loads all in_ch values per pixel
//
// Optimizations (v3+):
//   ① DW 12-ch parallel: all 12 SA rows compute different DW channels each tile.
//      SA dw_mode=1: acc[r] += act_in[r] * wgt_in[r][0]  (diagonal multiply).
//   ② Overlap ACT_LOAD: during last c_out tile WRITEBACK, load first 12
//      input-channel activations of the next spatial position.
//      Saves 12 cycles per spatial position (PW path only).
//   ③ Merge BIAS_LOAD: during WRITEBACK (non-last c_out tile), simultaneously
//      preload next tile's 12 biases into bias_stage_reg.
//      Reduces per-tile overhead from 13 → 1 cycle (just sa_clear).
//   ④ 12-channel-wide activation fetch: pixel_in is a 12-lane bus and the
//      external memory returns 12 consecutive channels per cycle.
//      PW S_ACT_LOAD loads 12 ch/cycle (was 1); DW S_DW12_FETCH loads all 12
//      channels of a kernel position in 1 cycle (was 12).  std-conv and
//      global-DW keep the narrow 1-ch path (non-contiguous access pattern).
//
// =============================================================================

module mfn_controller_v3 #(
    parameter int DWIDTH  = 16,
    parameter int AWIDTH  = 40,
    parameter int SA_ROWS = 12,   // output-channel parallel degree
    parameter int SA_COLS = 12    // input-channel parallel degree
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    output logic              done,

    // Layer config ROM interface
    output logic [5:0]        layer_idx,
    input  logic [63:0]       layer_config,
    input  logic              layer_is_pw,
    input  logic              layer_is_res,

    // Pixel / activation address output to external buffer.
    // c_in_out is the BASE channel; external memory returns 12 consecutive
    // channels (opt ④).  pixel data itself goes straight to act_buf, not here.
    output logic              reset_ptr,
    output logic              inc_write,
    output logic              read_res,
    output logic signed [8:0] x_out,
    output logic signed [8:0] y_out,
    output logic [9:0]        c_in_out,     // base channel address for pixel read

    // Activation buffer control
    output logic                        act_load_en,
    output logic                        act_load_wide, // 1=12-ch wide load (opt ④)
    output logic [$clog2(512)-1:0]      act_load_ch,
    output logic [$clog2(512)-1:0]      act_base_ch,  // c_in_tile start for SA
    output logic [9:0]                  act_max_ch,   // dynamic channel ceiling for act_buf

    // SA control
    output logic              sa_clear,    // load bias into SA accumulators
    output logic              sa_enable,   // compute cycle
    output logic              sa_dw_mode,  // 1=DW diagonal mode (opt ①)
    output logic signed [AWIDTH-1:0] sa_bias_in [SA_ROWS], // 12 biases to SA

    // Weight ROM address (one per SA row)
    output logic [19:0]       wgt_addr [SA_ROWS],

    // Bias ROM
    output logic [13:0]       bias_addr,

    // PSUM SRAM interface (reuse mfn_psum_sram ports)
    output logic              psum_we_a,
    output logic [8:0]        psum_waddr_a,
    output logic [AWIDTH-1:0] psum_wdata_a,
    output logic              psum_we_b,
    output logic [8:0]        psum_waddr_b,
    output logic [AWIDTH-1:0] psum_wdata_b,
    output logic [8:0]        psum_raddr_c,
    input  logic [AWIDTH-1:0] psum_rdata_a, // read during writeback
    input  logic [AWIDTH-1:0] psum_rdata_c, // for activation output

    // SA result readback
    input  logic signed [AWIDTH-1:0] sa_acc [SA_ROWS],

    // Activation module
    output logic [AWIDTH-1:0] psum_to_act,
    input  logic [AWIDTH-1:0] mac_bias_in   // from bias ROM
);

    // =========================================================================
    // FSM states
    // =========================================================================
    typedef enum logic [5:0] {
        S_IDLE,
        S_LOAD_CFG,
        S_WAIT_CFG,
        // PW / standard path
        S_ACT_LOAD,          // pre-load all in_ch activations into act_buf
        S_COUT_INIT,         // reset c_out_tile counter, start bias load
        S_BIAS_LOAD,         // 12+1 cycles: load biases; or 1 cycle if preloaded (opt ③)
        S_CIN_COMPUTE,       // 1 cycle per c_in tile: SA enable
        S_NEXT_CIN,          // advance c_in_tile, loop or go to writeback
        S_WRITEBACK,         // 12 cycles: write SA acc → psum SRAM
                             //   [opt ③] simultaneously load next tile's biases
                             //   [opt ②] on last cout tile: simultaneously load next pos acts
        S_NEXT_COUT,         // advance c_out_tile or go to write_out
        // Global DW path (unchanged from v1)
        S_DW_CTILE_INIT,
        S_DW_BIAS_LOAD,      // global DW only: 1-cycle bias load
        S_DW_FETCH,          // global DW only
        S_DW_COMPUTE,        // global DW only
        S_DW_WRITEBACK,      // global DW only
        S_DW_NEXT_CTILE,     // global DW only
        // Regular DW 12-ch parallel path (opt ①)
        S_DW12_BIAS,         // 12+1 cycles: load biases for 12 DW channels
        S_DW12_FETCH,        // 1 cycle: 12-ch wide fetch at kernel pos kp (opt ④)
        S_DW12_COMPUTE,      // 1 cycle: SA enable (dw_mode=1)
        S_DW12_KP_NEXT,      // advance kernel pos or go to writeback
        S_DW12_WB,           // 12 cycles: writeback + preload next tile biases (opt ③)
        S_DW12_NEXT,         // advance dw_ctile by 12 or go to write_out
        // Shared tail
        S_READ_RESIDUAL,
        S_READ_RESIDUAL_WAIT,
        S_ADD_RESIDUAL,
        S_WRITE_OUT,         // inc_write + activation output
        S_SPATIAL_LOOP,
        S_NEXT_LAYER_WAIT,
        S_NEXT_LAYER,
        S_DONE
    } state_t;

    state_t state_reg, state_next;

    // =========================================================================
    // Config decode
    // =========================================================================
    logic [9:0]  layer_in_ch, layer_out_ch;
    logic [6:0]  layer_w, layer_h;
    logic [1:0]  layer_stride;
    logic        layer_is_dw;
    logic [19:0] layer_wgt_base;
    logic [5:0]  layer_idx_reg, layer_idx_next;

    assign layer_in_ch    = layer_config[9:0];
    assign layer_out_ch   = layer_config[19:10];
    assign layer_w        = layer_config[26:20];
    assign layer_h        = layer_config[33:27];
    assign layer_stride   = layer_config[35:34];
    assign layer_is_dw    = layer_config[39];
    assign layer_wgt_base = layer_config[59:40];
    assign layer_idx      = layer_idx_reg;

    logic [1:0] layer_rd_buf, layer_wr_buf;
    assign layer_rd_buf = layer_config[61:60];
    assign layer_wr_buf = layer_config[63:62];

    logic is_global_dw, is_std_conv;
    assign is_global_dw = layer_is_pw & layer_is_dw;
    assign is_std_conv  = !layer_is_pw & !layer_is_dw;

    // =========================================================================
    // Loop counters and state registers
    // =========================================================================
    logic signed [8:0]  x_reg, x_next;
    logic signed [8:0]  y_reg, y_next;

    logic [9:0]  c_in_tile_reg,  c_in_tile_next;
    logic [9:0]  c_out_tile_reg, c_out_tile_next;

    // sub-counters: within BIAS_LOAD / WRITEBACK / DW12 fetch (0..SA_ROWS-1)
    logic [5:0]  sub_k_reg, sub_k_next;

    // Kernel position counter for DW12 (0..8)
    logic [3:0]  kp_reg, kp_next;

    // Global DW pixel coordinates (incremented during S_DW_FETCH when is_global_dw)
    logic [2:0]  gdw_kx_reg, gdw_kx_next;
    logic [2:0]  gdw_ky_reg, gdw_ky_next;

    logic [17:0] wgt_step_reg, wgt_step_next;
    logic [13:0] bias_base_reg, bias_base_next;

    logic [9:0]  eff_in_ch_reg,  eff_in_ch_next;

    // DW channel tile base: advances by SA_ROWS in DW12 path
    localparam int DW_ACT_BASE = 503;  // 512 - 9 (global DW / fallback)
    logic [9:0]  dw_ctile_reg, dw_ctile_next;

    // SA bias staging registers
    logic signed [AWIDTH-1:0] bias_stage_reg [SA_ROWS];
    logic signed [AWIDTH-1:0] bias_stage_next[SA_ROWS];

    // [opt ③] flag: biases for current tile already staged during previous WRITEBACK
    logic bias_preloaded_reg, bias_preloaded_next;

    // [opt ②] flag: first 12 act-buf channels already loaded during previous WRITEBACK
    logic act_preloaded_reg, act_preloaded_next;

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg         <= S_IDLE;
            layer_idx_reg     <= '0;
            x_reg <= '0; y_reg <= '0;
            c_in_tile_reg     <= '0;
            c_out_tile_reg    <= '0;
            sub_k_reg         <= '0;
            kp_reg            <= '0;
            wgt_step_reg      <= '0;
            bias_base_reg     <= '0;
            eff_in_ch_reg     <= '0;
            dw_ctile_reg      <= '0;
            gdw_kx_reg        <= '0;
            gdw_ky_reg        <= '0;
            bias_preloaded_reg <= 1'b0;
            act_preloaded_reg  <= 1'b0;
            foreach (bias_stage_reg[i]) bias_stage_reg[i] <= '0;
        end else begin
            state_reg         <= state_next;
            layer_idx_reg     <= layer_idx_next;
            x_reg             <= x_next;
            y_reg             <= y_next;
            c_in_tile_reg     <= c_in_tile_next;
            c_out_tile_reg    <= c_out_tile_next;
            sub_k_reg         <= sub_k_next;
            kp_reg            <= kp_next;
            wgt_step_reg      <= wgt_step_next;
            bias_base_reg     <= bias_base_next;
            eff_in_ch_reg     <= eff_in_ch_next;
            dw_ctile_reg      <= dw_ctile_next;
            gdw_kx_reg        <= gdw_kx_next;
            gdw_ky_reg        <= gdw_ky_next;
            bias_preloaded_reg <= bias_preloaded_next;
            act_preloaded_reg  <= act_preloaded_next;
            foreach (bias_stage_reg[i]) bias_stage_reg[i] <= bias_stage_next[i];
        end
    end

    // =========================================================================
    // Combinational helpers
    // =========================================================================
    function automatic logic [17:0] pw_wgt_step(input [9:0] in_ch);
        return ((in_ch + 10'd8) / 10'd9) * 10'd9;
    endfunction

    // Std-conv spatial decode (layer 0 only)
    logic [9:0]       std_ic;
    logic [3:0]       std_k;
    logic signed [1:0] std_kx, std_ky;

    always_comb begin : std_conv_decode
        if      (c_in_tile_reg < 10'd9)  begin std_ic = 10'd0; std_k = c_in_tile_reg[3:0];         end
        else if (c_in_tile_reg < 10'd18) begin std_ic = 10'd1; std_k = c_in_tile_reg[3:0] - 4'd9;  end
        else                              begin std_ic = 10'd2; std_k = c_in_tile_reg[3:0] - 4'd18; end

        case (std_k)
            4'd0: begin std_ky = -2'sd1; std_kx = -2'sd1; end
            4'd1: begin std_ky = -2'sd1; std_kx =  2'sd0; end
            4'd2: begin std_ky = -2'sd1; std_kx =  2'sd1; end
            4'd3: begin std_ky =  2'sd0; std_kx = -2'sd1; end
            4'd4: begin std_ky =  2'sd0; std_kx =  2'sd0; end
            4'd5: begin std_ky =  2'sd0; std_kx =  2'sd1; end
            4'd6: begin std_ky =  2'sd1; std_kx = -2'sd1; end
            4'd7: begin std_ky =  2'sd1; std_kx =  2'sd0; end
            4'd8: begin std_ky =  2'sd1; std_kx =  2'sd1; end
            default: begin std_ky = 2'sd0; std_kx = 2'sd0; end
        endcase
    end

    // [opt ②] next spatial position (for PW preload during WRITEBACK)
    logic [8:0] nxt_x, nxt_y;
    logic       is_last_x, is_last_spatial;
    assign is_last_x       = (x_reg >= 9'(layer_w) - 9'(layer_stride));
    assign is_last_spatial = is_last_x && (y_reg >= 9'(layer_h) - 9'(layer_stride));

    always_comb begin
        if (is_last_x) begin
            nxt_x = '0;
            nxt_y = y_reg + 9'(layer_stride);
        end else begin
            nxt_x = x_reg + 9'(layer_stride);
            nxt_y = y_reg;
        end
    end

    // [opt ③] is this the last c_out tile?
    logic is_last_cout;
    assign is_last_cout = (c_out_tile_reg + SA_ROWS >= layer_out_ch);

    // [opt ①] DW12 kernel-position offsets  kp = ky*3+kx; kx,ky in {0,1,2}
    logic signed [8:0] kp_x_off, kp_y_off;
    always_comb begin
        automatic int kx_i, ky_i;
        kx_i    = int'(kp_reg) % 3;
        ky_i    = int'(kp_reg) / 3;
        kp_x_off = 9'(kx_i) - 9'sd1;
        kp_y_off = 9'(ky_i) - 9'sd1;
    end

    // is_last_dw12_tile: true when dw_ctile_reg + SA_ROWS covers all channels
    logic is_last_dw12;
    assign is_last_dw12 = (dw_ctile_reg + 10'(SA_ROWS) >= layer_out_ch);

    // =========================================================================
    // Combinational next-state and output logic
    // =========================================================================
    always_comb begin
        // Default: hold everything
        state_next         = state_reg;
        layer_idx_next     = layer_idx_reg;
        x_next = x_reg; y_next = y_reg;
        c_in_tile_next     = c_in_tile_reg;
        c_out_tile_next    = c_out_tile_reg;
        sub_k_next         = sub_k_reg;
        kp_next            = kp_reg;
        wgt_step_next      = wgt_step_reg;
        bias_base_next     = bias_base_reg;
        eff_in_ch_next     = eff_in_ch_reg;
        dw_ctile_next      = dw_ctile_reg;
        gdw_kx_next        = gdw_kx_reg;
        gdw_ky_next        = gdw_ky_reg;
        bias_preloaded_next = bias_preloaded_reg;
        act_preloaded_next  = act_preloaded_reg;
        foreach (bias_stage_next[i]) bias_stage_next[i] = bias_stage_reg[i];

        // Default outputs (inactive)
        done        = 1'b0;
        reset_ptr   = 1'b0;
        inc_write   = 1'b0;
        read_res    = 1'b0;
        x_out       = x_reg;
        y_out       = y_reg;
        c_in_out    = '0;
        act_load_en = 1'b0;
        act_load_wide = 1'b0;
        act_load_ch = '0;
        act_base_ch = '0;
        act_max_ch  = 10'd512;
        sa_clear    = 1'b0;
        sa_enable   = 1'b0;
        sa_dw_mode  = 1'b0;
        foreach (sa_bias_in[i]) sa_bias_in[i] = bias_stage_reg[i];
        foreach (wgt_addr[i])   wgt_addr[i] = '0;
        bias_addr   = '0;
        psum_we_a   = 1'b0;
        psum_waddr_a = '0;
        psum_wdata_a = '0;
        psum_we_b    = 1'b0;
        psum_waddr_b = '0;
        psum_wdata_b = '0;
        psum_raddr_c = '0;
        psum_to_act  = psum_rdata_c;

        case (state_reg)

            // ------------------------------------------------------------------
            S_IDLE: begin
                if (start) state_next = S_LOAD_CFG;
            end

            // ------------------------------------------------------------------
            S_LOAD_CFG: begin
                state_next = S_WAIT_CFG;
                x_next = '0; y_next = '0;
                c_out_tile_next = '0; c_in_tile_next = '0;
                bias_preloaded_next = 1'b0;
                act_preloaded_next  = 1'b0;
            end

            // ------------------------------------------------------------------
            S_WAIT_CFG: begin
                if (is_global_dw) begin
                    wgt_step_next  = 18'd45;
                    eff_in_ch_next = 10'd9;
                end else if (layer_is_dw) begin
                    wgt_step_next  = 18'd9;
                    eff_in_ch_next = 10'd9;
                end else if (is_std_conv) begin
                    wgt_step_next  = {8'b0, layer_in_ch} * 18'd9;
                    eff_in_ch_next = layer_in_ch * 10'd9;
                end else begin
                    wgt_step_next  = pw_wgt_step(layer_in_ch);
                    eff_in_ch_next = layer_in_ch;
                end
                state_next = layer_is_dw ? S_DW_CTILE_INIT : S_ACT_LOAD;
                c_in_tile_next  = '0;
                c_out_tile_next = '0;
                dw_ctile_next   = '0;
            end

            // ------------------------------------------------------------------
            S_ACT_LOAD: begin
                act_load_en = 1'b1;
                act_load_ch = c_in_tile_reg[$clog2(512)-1:0];

                if (is_std_conv) begin
                    // std conv (layer 0): narrow 1-ch load — each c_in_tile maps
                    // to a distinct (channel, kernel-pos) so a 12-ch wide read
                    // does not apply.  Step c_in_tile by 1.
                    act_load_wide = 1'b0;
                    c_in_out = std_ic;
                    x_out    = x_reg + {{7{std_kx[1]}}, std_kx};
                    y_out    = y_reg + {{7{std_ky[1]}}, std_ky};

                    if (c_in_tile_reg == eff_in_ch_reg - 1) begin
                        c_in_tile_next  = '0;
                        c_out_tile_next = '0;
                        state_next      = S_COUT_INIT;
                    end else begin
                        c_in_tile_next = c_in_tile_reg + 1'b1;
                    end
                end else begin
                    // [opt ④] PW conv: 12-channel-wide load — fetch 12 contiguous
                    // input channels at (x,y) per cycle.  Step c_in_tile by SA_COLS.
                    act_load_wide = 1'b1;
                    c_in_out = c_in_tile_reg;
                    x_out    = x_reg;
                    y_out    = y_reg;

                    if (c_in_tile_reg + SA_COLS >= eff_in_ch_reg) begin
                        c_in_tile_next  = '0;
                        c_out_tile_next = '0;
                        state_next      = S_COUT_INIT;
                    end else begin
                        c_in_tile_next = c_in_tile_reg + SA_COLS;
                    end
                end
            end

            // ------------------------------------------------------------------
            S_COUT_INIT: begin
                sub_k_next  = '0;
                state_next  = S_BIAS_LOAD;
                bias_addr   = bias_base_reg + {4'b0, c_out_tile_reg};
            end

            // ------------------------------------------------------------------
            // [opt ③] BIAS_LOAD: when bias_preloaded_reg, only 1 cycle (sa_clear)
            //         Otherwise: 12 load + 1 sa_clear = 13 cycles
            // ------------------------------------------------------------------
            S_BIAS_LOAD: begin
                if (bias_preloaded_reg && sub_k_reg == '0) begin
                    // Biases already in bias_stage_reg from previous WRITEBACK
                    sa_clear           = 1'b1;
                    bias_preloaded_next = 1'b0;
                    sub_k_next         = '0;
                    c_in_tile_next     = '0;
                    state_next         = S_CIN_COMPUTE;
                end else if (sub_k_reg == SA_ROWS) begin
                    sa_clear       = 1'b1;
                    sub_k_next     = '0;
                    c_in_tile_next = '0;
                    state_next     = S_CIN_COMPUTE;
                end else begin
                    bias_addr = bias_base_reg
                              + {4'b0, c_out_tile_reg[9:0]}
                              + {10'b0, sub_k_reg};
                    bias_stage_next[sub_k_reg] = mac_bias_in;
                    sub_k_next = sub_k_reg + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            S_CIN_COMPUTE: begin
                sa_enable   = 1'b1;
                act_base_ch = c_in_tile_reg[$clog2(512)-1:0];
                act_max_ch  = {1'b0, eff_in_ch_reg};

                for (int r = 0; r < SA_ROWS; r++) begin
                    logic [9:0]  cout_r;
                    logic [19:0] cout_wgt_offset;
                    cout_r          = c_out_tile_reg + 10'(r);
                    cout_wgt_offset = {10'b0, cout_r} * {2'b0, wgt_step_reg};
                    if (cout_r < layer_out_ch)
                        wgt_addr[r] = layer_wgt_base + cout_wgt_offset
                                    + {10'b0, c_in_tile_reg};
                    else
                        wgt_addr[r] = '0;
                end

                state_next = S_NEXT_CIN;
            end

            // ------------------------------------------------------------------
            S_NEXT_CIN: begin
                if (c_in_tile_reg + SA_COLS >= eff_in_ch_reg) begin
                    sub_k_next     = '0;
                    c_in_tile_next = '0;
                    state_next     = S_WRITEBACK;
                end else begin
                    c_in_tile_next = c_in_tile_reg + SA_COLS;
                    state_next     = S_CIN_COMPUTE;
                end
            end

            // ------------------------------------------------------------------
            // [opt ②] + [opt ③] WRITEBACK: 12 cycles
            //   Always: write sa_acc[sub_k] → psum SRAM
            //   opt ③: if NOT last cout tile → simultaneously load next tile biases
            //   opt ②: if IS last cout tile AND not last spatial pos (PW only)
            //           → simultaneously preload first 12 acts of next spatial pos
            // ------------------------------------------------------------------
            S_WRITEBACK: begin
                // ── Core writeback ────────────────────────────────────────────
                begin
                    logic [9:0] cout_ch;
                    cout_ch = c_out_tile_reg + {6'b0, sub_k_reg};
                    if (cout_ch < layer_out_ch) begin
                        psum_we_a    = 1'b1;
                        psum_waddr_a = cout_ch[8:0];
                        psum_wdata_a = sa_acc[sub_k_reg];
                    end
                end

                // ── [opt ③] preload next cout tile biases ─────────────────────
                if (!is_last_cout) begin
                    begin
                        logic [9:0] next_cout_ch;
                        next_cout_ch = c_out_tile_reg + 10'(SA_ROWS) + {6'b0, sub_k_reg};
                        bias_addr = bias_base_reg + {4'b0, next_cout_ch};
                    end
                    bias_stage_next[sub_k_reg] = mac_bias_in;
                    if (sub_k_reg == 6'(SA_ROWS - 1))
                        bias_preloaded_next = 1'b1;
                end

                // ── [opt ②] preload next spatial pos acts (PW only) ──────────
                if (is_last_cout && !is_last_spatial && !layer_is_dw && !is_std_conv) begin
                    act_load_en = 1'b1;
                    act_load_ch = {3'b0, sub_k_reg};
                    c_in_out    = {4'b0, sub_k_reg};   // input ch 0..11
                    x_out       = nxt_x;
                    y_out       = nxt_y;
                    if (sub_k_reg == 6'(SA_ROWS - 1))
                        act_preloaded_next = 1'b1;
                end

                // ── Advance sub_k / next state ────────────────────────────────
                if (sub_k_reg == 6'(SA_ROWS - 1)) begin
                    sub_k_next = '0;
                    state_next = S_NEXT_COUT;
                end else begin
                    sub_k_next = sub_k_reg + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            S_NEXT_COUT: begin
                if (is_last_cout) begin
                    c_out_tile_next = '0;
                    if (layer_is_res)
                        state_next = S_READ_RESIDUAL;
                    else
                        state_next = S_WRITE_OUT;
                end else begin
                    c_out_tile_next = c_out_tile_reg + SA_ROWS;
                    sub_k_next      = '0;
                    state_next      = S_BIAS_LOAD;
                end
            end

            // ------------------------------------------------------------------
            // DW dispatch: global DW keeps original 1-ch serial path;
            //              regular DW uses new 12-ch parallel path (opt ①)
            // ------------------------------------------------------------------
            S_DW_CTILE_INIT: begin
                sub_k_next     = '0;
                gdw_kx_next    = '0;
                gdw_ky_next    = '0;
                c_in_tile_next = '0;
                kp_next        = '0;
                if (is_global_dw)
                    state_next = S_DW_BIAS_LOAD;
                else
                    state_next = S_DW12_BIAS;
            end

            // ── Global DW path (unchanged) ────────────────────────────────────
            S_DW_BIAS_LOAD: begin
                bias_addr          = bias_base_reg + {4'b0, dw_ctile_reg};
                bias_stage_next[0] = mac_bias_in;
                sub_k_next         = '0;
                gdw_kx_next        = '0;
                gdw_ky_next        = '0;
                c_in_tile_next     = '0;
                state_next         = S_DW_FETCH;
            end

            S_DW_FETCH: begin
                c_in_out    = dw_ctile_reg;
                act_load_en = 1'b1;

                if (sub_k_reg == '0) sa_clear = 1'b1;

                if (is_global_dw) begin
                    x_out = {6'b0, gdw_kx_reg};
                    y_out = {6'b0, gdw_ky_reg};
                    act_load_ch = {3'b0, sub_k_reg};

                    if (gdw_kx_reg == 3'(layer_w - 1)) begin
                        gdw_kx_next = '0;
                        gdw_ky_next = gdw_ky_reg + 1'b1;
                    end else begin
                        gdw_kx_next = gdw_kx_reg + 1'b1;
                    end

                    if ({3'b0, sub_k_reg} == {2'b0, layer_w} * {2'b0, layer_h} - 7'd1) begin
                        sub_k_next     = '0;
                        c_in_tile_next = '0;
                        gdw_kx_next    = '0;
                        gdw_ky_next    = '0;
                        state_next     = S_DW_COMPUTE;
                    end else begin
                        sub_k_next = sub_k_reg + 1'b1;
                    end
                end else begin
                    // Should not reach here for regular DW (handled in DW12 path)
                    state_next = S_IDLE;
                end
            end

            S_DW_COMPUTE: begin
                sa_enable = 1'b1;
                if (is_global_dw) begin
                    act_base_ch = c_in_tile_reg[$clog2(512)-1:0] * 9'd12;
                    act_max_ch  = {3'b0, layer_w} * {3'b0, layer_h};
                    for (int r = 0; r < SA_ROWS; r++) begin
                        logic [19:0] gdw_ch_off, gdw_tile_off;
                        gdw_ch_off   = {10'b0, dw_ctile_reg} * {2'b0, wgt_step_reg};
                        gdw_tile_off = {10'b0, c_in_tile_reg} * 20'd12;
                        wgt_addr[r]  = layer_wgt_base + gdw_ch_off + gdw_tile_off;
                    end
                    if (c_in_tile_reg * 10'd12 + 10'd12 >=
                            {3'b0, layer_w} * {3'b0, layer_h}) begin
                        c_in_tile_next = '0;
                        state_next     = S_DW_WRITEBACK;
                    end else begin
                        c_in_tile_next = c_in_tile_reg + 1'b1;
                    end
                end else begin
                    state_next = S_IDLE; // should not occur
                end
            end

            S_DW_WRITEBACK: begin
                if (dw_ctile_reg < layer_out_ch) begin
                    psum_we_a    = 1'b1;
                    psum_waddr_a = dw_ctile_reg[8:0];
                    psum_wdata_a = sa_acc[0];
                end
                state_next = S_DW_NEXT_CTILE;
            end

            S_DW_NEXT_CTILE: begin
                if (dw_ctile_reg + 10'd1 >= layer_out_ch) begin
                    dw_ctile_next = '0;
                    state_next    = layer_is_res ? S_READ_RESIDUAL : S_WRITE_OUT;
                end else begin
                    dw_ctile_next = dw_ctile_reg + 10'd1;
                    state_next    = S_DW_BIAS_LOAD;
                end
            end

            // ── Regular DW 12-ch parallel path (opt ①) ───────────────────────
            // Bias load: 12 biases for channels dw_ctile..dw_ctile+11
            // When bias_preloaded_reg (set by DW12_WB): only sa_clear (1 cycle)
            S_DW12_BIAS: begin
                if (bias_preloaded_reg && sub_k_reg == '0) begin
                    sa_clear            = 1'b1;
                    bias_preloaded_next = 1'b0;
                    sub_k_next          = '0;
                    kp_next             = '0;
                    state_next          = S_DW12_FETCH;
                end else if (sub_k_reg == 6'(SA_ROWS)) begin
                    // All 12 biases loaded; assert sa_clear
                    sa_clear   = 1'b1;
                    sub_k_next = '0;
                    kp_next    = '0;
                    state_next = S_DW12_FETCH;
                end else begin
                    begin
                        logic [9:0] dw_ch;
                        dw_ch     = dw_ctile_reg + {6'b0, sub_k_reg};
                        bias_addr = bias_base_reg + {4'b0, dw_ch};
                    end
                    bias_stage_next[sub_k_reg] = mac_bias_in;
                    sub_k_next = sub_k_reg + 1'b1;
                end
            end

            // [opt ④] Fetch all 12 DW channels (dw_ctile..dw_ctile+11) for the
            // current kernel position kp in a single 12-ch-wide cycle.
            S_DW12_FETCH: begin
                c_in_out      = dw_ctile_reg;          // base channel
                act_load_en   = 1'b1;
                act_load_wide = 1'b1;
                act_load_ch   = '0;                    // act_buf[0..11]
                x_out         = x_reg + kp_x_off;
                y_out         = y_reg + kp_y_off;
                sub_k_next    = '0;
                state_next    = S_DW12_COMPUTE;
            end

            // 1 SA enable cycle: dw_mode → acc[r] += act_buf[r] * wgt[r][0]
            S_DW12_COMPUTE: begin
                sa_enable  = 1'b1;
                sa_dw_mode = 1'b1;
                act_base_ch = '0;           // act_buf[0..11] = 12 channel pixels
                act_max_ch  = 10'(SA_ROWS); // only channels 0..11 valid
                for (int r = 0; r < SA_ROWS; r++) begin
                    logic [19:0] dw_off;
                    // wgt_addr[r] → wgt_out[r][0] = weight for channel(dw_ctile+r) at pos kp
                    dw_off     = ({10'b0, dw_ctile_reg} + 20'(r)) * {2'b0, wgt_step_reg};
                    wgt_addr[r] = layer_wgt_base + dw_off + {16'b0, kp_reg};
                end
                state_next = S_DW12_KP_NEXT;
            end

            S_DW12_KP_NEXT: begin
                if (kp_reg == 4'd8) begin
                    // All 9 kernel positions done
                    kp_next    = '0;
                    sub_k_next = '0;
                    state_next = S_DW12_WB;
                end else begin
                    kp_next    = kp_reg + 1'b1;
                    sub_k_next = '0;
                    state_next = S_DW12_FETCH;
                end
            end

            // Writeback 12 channels; [opt ③] preload next tile biases if not last
            S_DW12_WB: begin
                begin
                    logic [9:0] dw_ch;
                    dw_ch = dw_ctile_reg + {6'b0, sub_k_reg};
                    if (dw_ch < layer_out_ch) begin
                        psum_we_a    = 1'b1;
                        psum_waddr_a = dw_ch[8:0];
                        psum_wdata_a = sa_acc[sub_k_reg];
                    end
                end

                // [opt ③] preload next DW12 tile biases
                if (!is_last_dw12) begin
                    begin
                        logic [9:0] nxt_dw_ch;
                        nxt_dw_ch = dw_ctile_reg + 10'(SA_ROWS) + {6'b0, sub_k_reg};
                        bias_addr = bias_base_reg + {4'b0, nxt_dw_ch};
                    end
                    bias_stage_next[sub_k_reg] = mac_bias_in;
                    if (sub_k_reg == 6'(SA_ROWS - 1))
                        bias_preloaded_next = 1'b1;
                end

                if (sub_k_reg == 6'(SA_ROWS - 1)) begin
                    sub_k_next = '0;
                    state_next = S_DW12_NEXT;
                end else begin
                    sub_k_next = sub_k_reg + 1'b1;
                end
            end

            S_DW12_NEXT: begin
                if (is_last_dw12) begin
                    dw_ctile_next       = '0;
                    bias_preloaded_next = 1'b0;
                    state_next          = layer_is_res ? S_READ_RESIDUAL : S_WRITE_OUT;
                end else begin
                    dw_ctile_next = dw_ctile_reg + 10'(SA_ROWS);
                    state_next    = S_DW12_BIAS;
                end
            end

            // ------------------------------------------------------------------
            // Residual addition (unchanged from v1)
            // ------------------------------------------------------------------
            S_READ_RESIDUAL: begin
                read_res     = 1'b1;
                psum_raddr_c = c_out_tile_reg[8:0];
                c_in_out     = c_out_tile_reg;
                state_next   = S_READ_RESIDUAL_WAIT;
            end

            S_READ_RESIDUAL_WAIT: begin
                read_res     = 1'b1;
                psum_raddr_c = c_out_tile_reg[8:0];
                c_in_out     = c_out_tile_reg;
                state_next   = S_ADD_RESIDUAL;
            end

            S_ADD_RESIDUAL: begin
                inc_write    = 1'b1;
                read_res     = 1'b1;
                psum_raddr_c = c_out_tile_reg[8:0];
                c_in_out     = c_out_tile_reg;
                if (c_out_tile_reg + 1 >= layer_out_ch) begin
                    c_out_tile_next = '0;
                    state_next      = S_SPATIAL_LOOP;
                end else begin
                    c_out_tile_next = c_out_tile_reg + 1'b1;
                    state_next      = S_READ_RESIDUAL;
                end
            end

            // ------------------------------------------------------------------
            S_WRITE_OUT: begin
                inc_write    = 1'b1;
                psum_raddr_c = c_out_tile_reg[8:0];
                psum_to_act  = psum_rdata_c;
                bias_addr    = bias_base_reg + {4'b0, c_out_tile_reg[9:0]};
                if (c_out_tile_reg + 1 >= layer_out_ch) begin
                    c_out_tile_next = '0;
                    state_next      = S_SPATIAL_LOOP;
                end else begin
                    c_out_tile_next = c_out_tile_reg + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            // [opt ②] SPATIAL_LOOP: if act_preloaded_reg, start ACT_LOAD at ch 12
            // ------------------------------------------------------------------
            S_SPATIAL_LOOP: begin
                wgt_step_next = wgt_step_reg;
                if (is_global_dw) begin
                    state_next = S_NEXT_LAYER_WAIT;
                end else if (x_reg >= 9'(layer_w) - 9'(layer_stride)) begin
                    x_next = '0;
                    if (y_reg >= 9'(layer_h) - 9'(layer_stride)) begin
                        y_next = '0;
                        act_preloaded_next  = 1'b0;
                        bias_preloaded_next = 1'b0;
                        state_next = S_NEXT_LAYER_WAIT;
                    end else begin
                        y_next = y_reg + 9'(layer_stride);
                        c_in_tile_next  = act_preloaded_reg ? 10'(SA_ROWS) : '0;
                        c_out_tile_next = '0;
                        dw_ctile_next   = '0;
                        act_preloaded_next  = 1'b0;
                        bias_preloaded_next = 1'b0;
                        state_next = layer_is_dw ? S_DW_CTILE_INIT : S_ACT_LOAD;
                    end
                end else begin
                    x_next = x_reg + 9'(layer_stride);
                    c_in_tile_next  = act_preloaded_reg ? 10'(SA_ROWS) : '0;
                    c_out_tile_next = '0;
                    dw_ctile_next   = '0;
                    act_preloaded_next  = 1'b0;
                    bias_preloaded_next = 1'b0;
                    state_next = layer_is_dw ? S_DW_CTILE_INIT : S_ACT_LOAD;
                end
            end

            // ------------------------------------------------------------------
            S_NEXT_LAYER_WAIT: state_next = S_NEXT_LAYER;

            S_NEXT_LAYER: begin
                if (layer_idx_reg >= 6'd49) begin
                    state_next = S_DONE;
                end else begin
                    bias_base_next      = bias_base_reg + {4'b0, layer_out_ch};
                    layer_idx_next      = layer_idx_reg + 1'b1;
                    bias_preloaded_next = 1'b0;
                    act_preloaded_next  = 1'b0;
                    state_next          = S_LOAD_CFG;
                    reset_ptr           = 1'b1;
                end
            end

            S_DONE: begin
                done       = 1'b1;
                state_next = S_IDLE;
            end

            default: state_next = S_IDLE;
        endcase
    end

endmodule
