// =============================================================================
// mfn_controller_v3.sv — Tiled SA Controller for MobileFaceNet v3
//
// Key differences from v2 controller:
//   1. PW conv  → output-stationary 12×12 SA tiles (c_out × c_in)
//   2. DW conv  → 4-channel parallel (4 SA rows, 9-point kernel, wide fetch)
//   3. Standard 3×3 → SA with in_ch=3 (falls through PW path after sliding window)
//   4. Activation buffer (mfn_act_buf) pre-loads all in_ch values per pixel
//      before SA compute; this adds in_ch cycles load overhead per spatial pos
//      but allows 12 c_in per SA cycle instead of 9 per FETCH in v2.
//
// FSM high-level flow (PW layers, dominant workload):
//   LOAD_CFG → WAIT_CFG
//   ┌─ spatial loop (x, y) ──────────────────────────────────────────────────┐
//   │  ACT_LOAD (in_ch cycles): fill act_buf with all input channels         │
//   │  ┌─ c_out tile loop (12 channels at a time) ──────────────────────┐   │
//   │  │  BIAS_LOAD (12 cycles): SA clear + load bias into accumulators  │   │
//   │  │  ┌─ c_in tile loop (12 channels at a time) ──────────────────┐ │   │
//   │  │  │  COMPUTE (1 cycle): SA.enable — adds 12×12 products       │ │   │
//   │  │  └── next c_in_tile ─────────────────────────────────────────┘ │   │
//   │  │  WRITEBACK (12 cycles): acc_out[0..11] → psum_sram            │   │
//   │  └── next c_out_tile ──────────────────────────────────────────────┘   │
//   │  [if residual: read residual + add]                                    │
//   │  WRITE_OUT: activation → output SRAM                                   │
//   └─ SPATIAL_LOOP ─────────────────────────────────────────────────────────┘
//   NEXT_LAYER → DONE
//
// DW flow per spatial position (4 channels at a time):
//   ┌─ c_tile loop (4 DW channels at a time) ───────┐
//   │  BIAS_LOAD_DW (4 cycles)                       │
//   │  FETCH_DW (4 cycles, wide addr_gen)            │
//   │  COMPUTE_DW (1 cycle, only 4 SA rows active)   │
//   │  WRITEBACK_DW (4 cycles)                       │
//   └── next c_tile ──────────────────────────────────┘
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

    // Pixel / activation input (one channel per cycle from external buffer)
    output logic              reset_ptr,
    output logic              inc_write,
    output logic              read_res,
    output logic signed [8:0] x_out,
    output logic signed [8:0] y_out,
    output logic [9:0]        c_in_out,     // channel address for pixel read
    input  logic signed [DWIDTH-1:0] pixel_in,

    // Activation buffer control
    output logic                        act_load_en,
    output logic [$clog2(512)-1:0]      act_load_ch,
    output logic [$clog2(512)-1:0]      act_base_ch,  // c_in_tile start for SA
    output logic [9:0]                  act_max_ch,   // dynamic channel ceiling for act_buf

    // SA control
    output logic              sa_clear,    // load bias into SA accumulators
    output logic              sa_enable,   // compute cycle
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
        S_BIAS_LOAD,         // 12 cycles: SA clear + feed biases
        S_CIN_COMPUTE,       // 1 cycle per c_in tile: SA enable
        S_NEXT_CIN,          // advance c_in_tile, loop or go to writeback
        S_WRITEBACK,         // 12 cycles: write SA acc → psum SRAM
        S_NEXT_COUT,         // advance c_out_tile or go to write_out
        // DW path
        S_DW_CTILE_INIT,
        S_DW_BIAS_LOAD,      // 4 cycles
        S_DW_FETCH,          // 4 cycles (wide mode, addr_gen)
        S_DW_COMPUTE,        // 1 cycle
        S_DW_WRITEBACK,      // 4 cycles
        S_DW_NEXT_CTILE,
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

    // Buffer indices decoded from config (bits 61:60=rd_buf, 63:62=wr_buf)
    // TB uses these (hierarchically) to compute SRAM addresses.
    logic [1:0] layer_rd_buf, layer_wr_buf;
    assign layer_rd_buf = layer_config[61:60];
    assign layer_wr_buf = layer_config[63:62];

    logic is_global_dw, is_std_conv;
    assign is_global_dw = layer_is_pw & layer_is_dw;
    // standard conv: neither PW nor DW (only layer 0 in MFN)
    assign is_std_conv  = !layer_is_pw & !layer_is_dw;

    // =========================================================================
    // Loop counters
    // =========================================================================
    logic signed [8:0]  x_reg, x_next;
    logic signed [8:0]  y_reg, y_next;

    // c_in_tile: which group of SA_COLS input channels currently in the SA
    logic [9:0]  c_in_tile_reg,  c_in_tile_next;
    // c_out_tile: which group of SA_ROWS output channels currently in the SA
    logic [9:0]  c_out_tile_reg, c_out_tile_next;

    // sub-counters within BIAS_LOAD / WRITEBACK (0..SA_ROWS-1) or GDW fetch (0..41)
    logic [5:0]  sub_k_reg, sub_k_next;

    // Global DW pixel coordinates (incremented during S_DW_FETCH when is_global_dw)
    logic [2:0]  gdw_kx_reg, gdw_kx_next;  // 0..layer_w-1
    logic [2:0]  gdw_ky_reg, gdw_ky_next;  // 0..layer_h-1

    // Weight step per c_out channel (stride between OC blocks in weight memory)
    logic [17:0] wgt_step_reg, wgt_step_next;
    logic [13:0] bias_base_reg, bias_base_next;

    // Effective in_ch for ACT_LOAD and c_in tiling:
    //   PW         → layer_in_ch
    //   std conv   → layer_in_ch * 9  (= 27 for layer 0)
    logic [9:0]  eff_in_ch_reg,  eff_in_ch_next;

    // DW channel counter: 1 channel at a time (dw_ctile = current channel)
    // act_buf[DW_ACT_BASE..DW_ACT_BASE+8] store the 9 kernel pixels for DW.
    // DW_ACT_BASE = 503 ensures act_out[9..11] → idx>=512 → 0 (no stale contamination).
    localparam int DW_ACT_BASE = 503;  // 512 - 9
    logic [9:0]  dw_ctile_reg, dw_ctile_next;

    // SA bias staging registers (loaded during BIAS_LOAD)
    logic signed [AWIDTH-1:0] bias_stage_reg [SA_ROWS];
    logic signed [AWIDTH-1:0] bias_stage_next[SA_ROWS];

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg       <= S_IDLE;
            layer_idx_reg   <= '0;
            x_reg <= '0; y_reg <= '0;
            c_in_tile_reg   <= '0;
            c_out_tile_reg  <= '0;
            sub_k_reg       <= '0;
            wgt_step_reg    <= '0;
            bias_base_reg   <= '0;
            eff_in_ch_reg   <= '0;
            dw_ctile_reg    <= '0;
            gdw_kx_reg      <= '0;
            gdw_ky_reg      <= '0;
            foreach (bias_stage_reg[i]) bias_stage_reg[i] <= '0;
        end else begin
            state_reg       <= state_next;
            layer_idx_reg   <= layer_idx_next;
            x_reg           <= x_next;
            y_reg           <= y_next;
            c_in_tile_reg   <= c_in_tile_next;
            c_out_tile_reg  <= c_out_tile_next;
            sub_k_reg       <= sub_k_next;
            wgt_step_reg    <= wgt_step_next;
            bias_base_reg   <= bias_base_next;
            eff_in_ch_reg   <= eff_in_ch_next;
            dw_ctile_reg    <= dw_ctile_next;
            gdw_kx_reg      <= gdw_kx_next;
            gdw_ky_reg      <= gdw_ky_next;
            foreach (bias_stage_reg[i]) bias_stage_reg[i] <= bias_stage_next[i];
        end
    end

    // =========================================================================
    // Combinational next-state and output logic
    // =========================================================================
    // Weight step for PW: gen_hex.py pack_pw_weights packs in groups of 9,
    // so the stride between OC blocks is ceil(in_ch/9)*9.
    function automatic logic [17:0] pw_wgt_step(input [9:0] in_ch);
        return ((in_ch + 10'd8) / 10'd9) * 10'd9;
    endfunction

    // ── Std-conv spatial decode (layer 0 only: in_ch=3, virtual_ch = ic*9+k) ──
    // virtual_ch 0..8 → ic=0, k=0..8
    // virtual_ch 9..17 → ic=1, k=0..8
    // virtual_ch 18..26 → ic=2, k=0..8
    logic [9:0]       std_ic;    // input channel index for current virtual_ch
    logic [3:0]       std_k;     // spatial kernel index (0..8)
    logic signed [1:0] std_kx, std_ky;  // relative x/y offsets (-1,0,+1)

    always_comb begin : std_conv_decode
        if      (c_in_tile_reg < 10'd9)  begin std_ic = 10'd0; std_k = c_in_tile_reg[3:0];     end
        else if (c_in_tile_reg < 10'd18) begin std_ic = 10'd1; std_k = c_in_tile_reg[3:0] - 4'd9;  end
        else                              begin std_ic = 10'd2; std_k = c_in_tile_reg[3:0] - 4'd18; end

        // PyTorch conv weight order: k = ky*3+kx  →  ky=k/3, kx=k%3
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

    always_comb begin
        // Default: hold everything
        state_next       = state_reg;
        layer_idx_next   = layer_idx_reg;
        x_next = x_reg; y_next = y_reg;
        c_in_tile_next   = c_in_tile_reg;
        c_out_tile_next  = c_out_tile_reg;
        sub_k_next       = sub_k_reg;
        wgt_step_next    = wgt_step_reg;
        bias_base_next   = bias_base_reg;
        eff_in_ch_next   = eff_in_ch_reg;
        dw_ctile_next    = dw_ctile_reg;
        gdw_kx_next      = gdw_kx_reg;
        gdw_ky_next      = gdw_ky_reg;
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
        act_load_ch = '0;
        act_base_ch = '0;
        act_max_ch  = 10'd512;
        sa_clear    = 1'b0;
        sa_enable   = 1'b0;
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
            end

            // ------------------------------------------------------------------
            S_WAIT_CFG: begin
                if (is_global_dw) begin
                    // Global DW: kernel size = layer_w * layer_h (6×7=42),
                    // pack_global_dw_weights pads to ceil(42/9)*9=45 per channel
                    wgt_step_next  = 18'd45;
                    eff_in_ch_next = 10'd9;        // unused in DW path
                end else if (layer_is_dw) begin
                    wgt_step_next  = 18'd9;
                    eff_in_ch_next = 10'd9;        // DW path uses its own loop
                end else if (is_std_conv) begin
                    // standard 3×3 conv: virtual in_ch = in_ch*9 (27 for layer 0)
                    wgt_step_next  = {8'b0, layer_in_ch} * 18'd9;
                    eff_in_ch_next = layer_in_ch * 10'd9;
                end else begin
                    // PW: pack_pw_weights uses groups of 9 → stride = ceil(in_ch/9)*9
                    wgt_step_next  = pw_wgt_step(layer_in_ch);
                    eff_in_ch_next = layer_in_ch;
                end
                state_next = layer_is_dw ? S_DW_CTILE_INIT : S_ACT_LOAD;
                c_in_tile_next  = '0;
                c_out_tile_next = '0;
                dw_ctile_next   = '0;
            end

            // ------------------------------------------------------------------
            // PW / Standard: pre-load activations from pixel_in into act_buf.
            // PW:       load in_ch channels at (x,y); c_in_tile=0..in_ch-1
            // Std conv: load eff_in_ch=in_ch*9 virtual channels at 3×3 offsets;
            //           virtual_ch = ic*9+k → (x+kx, y+ky, ic)
            // ------------------------------------------------------------------
            S_ACT_LOAD: begin
                act_load_en = 1'b1;
                act_load_ch = c_in_tile_reg[$clog2(512)-1:0];

                if (is_std_conv) begin
                    // spatial + channel addressing for standard conv
                    c_in_out = std_ic;
                    x_out    = x_reg + {{7{std_kx[1]}}, std_kx};
                    y_out    = y_reg + {{7{std_ky[1]}}, std_ky};
                end else begin
                    c_in_out = c_in_tile_reg;
                    x_out    = x_reg;
                    y_out    = y_reg;
                end

                if (c_in_tile_reg == eff_in_ch_reg - 1) begin
                    c_in_tile_next  = '0;
                    c_out_tile_next = '0;
                    state_next      = S_COUT_INIT;
                end else begin
                    c_in_tile_next = c_in_tile_reg + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            S_COUT_INIT: begin
                // Start a new c_out tile; reset sub_k for bias loading
                sub_k_next  = '0;
                state_next  = S_BIAS_LOAD;
                bias_addr   = bias_base_reg + {4'b0, c_out_tile_reg};
            end

            // ------------------------------------------------------------------
            // BIAS_LOAD: 12 cycles load + 1 extra cycle for sa_clear
            //   sub_k 0..SA_ROWS-1: read bias ROM, latch into bias_stage_next[k]
            //   sub_k == SA_ROWS  : bias_stage_reg now has all 12 fresh values,
            //                       assert sa_clear so SA latches correct biases
            // ------------------------------------------------------------------
            S_BIAS_LOAD: begin
                if (sub_k_reg == SA_ROWS) begin
                    // Extra pipeline cycle: bias_stage_reg[11] is now updated
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
            // CIN_COMPUTE: 1 SA compute cycle per c_in tile
            // ------------------------------------------------------------------
            S_CIN_COMPUTE: begin
                sa_enable   = 1'b1;
                act_base_ch = c_in_tile_reg[$clog2(512)-1:0];
                act_max_ch  = {1'b0, eff_in_ch_reg};

                // Weight addresses: row r reads from wgt_base + (c_out_tile+r)*wgt_step + c_in_tile
                // Use 20-bit multiply to avoid 10-bit overflow (e.g. ch=38 * step=27 = 1026 > 1023)
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
                // Use eff_in_ch_reg: for std conv = in_ch*9, for PW = in_ch
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
            // WRITEBACK: 12 cycles — write SA acc[0..11] → psum SRAM
            // Use port A for even sub_k, port B for odd → 2 per cycle
            // (actually write 1 per cycle for simplicity; upgrade later)
            // ------------------------------------------------------------------
            S_WRITEBACK: begin
                logic [9:0] cout_ch;
                cout_ch = c_out_tile_reg + {6'b0, sub_k_reg};
                if (cout_ch < layer_out_ch) begin
                    psum_we_a    = 1'b1;
                    psum_waddr_a = cout_ch[8:0];
                    psum_wdata_a = sa_acc[sub_k_reg];
                end

                if (sub_k_reg == SA_ROWS - 1) begin
                    sub_k_next = '0;
                    state_next = S_NEXT_COUT;
                end else begin
                    sub_k_next = sub_k_reg + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            S_NEXT_COUT: begin
                if (c_out_tile_reg + SA_ROWS >= layer_out_ch) begin
                    // All c_out tiles done → activation output
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
            // DW path: 1 channel (dw_ctile_reg) at a time, 9 kernel positions.
            // Pixels stored in act_buf[DW_ACT_BASE..DW_ACT_BASE+8] (503..511)
            // so act_out[9..11] → idx>=512 → 0 (avoids stale value contamination).
            // Only SA row 0 result is used.
            // ------------------------------------------------------------------
            S_DW_CTILE_INIT: begin
                sub_k_next     = '0;
                gdw_kx_next    = '0;
                gdw_ky_next    = '0;
                c_in_tile_next = '0;
                state_next    = S_DW_BIAS_LOAD;
            end

            S_DW_BIAS_LOAD: begin
                // Load bias for current channel dw_ctile_reg into bias_stage[0]
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

                // On first load cycle: bias_stage_reg[0] is fresh → sa_clear now
                if (sub_k_reg == '0) sa_clear = 1'b1;

                if (is_global_dw) begin
                    // Global DW: sub_k = 0..layer_w*layer_h-1, fetch absolute (kx,ky)
                    x_out = {6'b0, gdw_kx_reg};
                    y_out = {6'b0, gdw_ky_reg};
                    act_load_ch = {3'b0, sub_k_reg};  // act_buf[0..41]

                    // Advance (kx, ky) — kx wraps at layer_w
                    if (gdw_kx_reg == 3'(layer_w - 1)) begin
                        gdw_kx_next = '0;
                        gdw_ky_next = gdw_ky_reg + 1'b1;
                    end else begin
                        gdw_kx_next = gdw_kx_reg + 1'b1;
                    end

                    // End when sub_k reaches layer_w*layer_h - 1
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
                    // Regular 3×3 DW: sub_k = 0..8, fetch (x+kx-1, y+ky-1)
                    begin
                        logic [1:0] kx_raw, ky_raw;
                        kx_raw = 2'(int'(sub_k_reg) % 3);
                        ky_raw = 2'(int'(sub_k_reg) / 3);
                        x_out = x_reg + $signed({7'b0, kx_raw}) - 9'sd1;
                        y_out = y_reg + $signed({7'b0, ky_raw}) - 9'sd1;
                    end
                    act_load_ch = 9'(DW_ACT_BASE) + {3'b0, sub_k_reg};

                    if (sub_k_reg == 6'd8) begin
                        sub_k_next = '0;
                        state_next = S_DW_COMPUTE;
                    end else begin
                        sub_k_next = sub_k_reg + 1'b1;
                    end
                end
            end

            S_DW_COMPUTE: begin
                sa_enable = 1'b1;
                if (is_global_dw) begin
                    // Global DW: 4 tiles of SA_COLS=12 covering 42 positions
                    // c_in_tile_reg = current tile (0..3)
                    // act_buf[tile*12 .. tile*12+11], max_ch=layer_w*layer_h=42
                    act_base_ch = c_in_tile_reg[$clog2(512)-1:0] * 9'd12;
                    act_max_ch  = {3'b0, layer_w} * {3'b0, layer_h};  // =42
                    for (int r = 0; r < SA_ROWS; r++) begin
                        logic [19:0] gdw_ch_off, gdw_tile_off;
                        gdw_ch_off   = {10'b0, dw_ctile_reg} * {2'b0, wgt_step_reg};
                        gdw_tile_off = {10'b0, c_in_tile_reg} * 20'd12;
                        wgt_addr[r]  = layer_wgt_base + gdw_ch_off + gdw_tile_off;
                    end
                    // Last tile when (tile+1)*12 >= layer_w*layer_h
                    if (c_in_tile_reg * 10'd12 + 10'd12 >=
                            {3'b0, layer_w} * {3'b0, layer_h}) begin
                        c_in_tile_next = '0;
                        state_next     = S_DW_WRITEBACK;
                    end else begin
                        c_in_tile_next = c_in_tile_reg + 1'b1;
                    end
                end else begin
                    // Regular DW: 1 MAC cycle, act_buf[DW_ACT_BASE..+11]
                    // act_out[9..11] → idx>=512 → 0 (no stale contamination)
                    act_base_ch = 9'(DW_ACT_BASE);
                    for (int r = 0; r < SA_ROWS; r++) begin
                        logic [19:0] dw_wgt_offset;
                        dw_wgt_offset = {10'b0, dw_ctile_reg} * {2'b0, wgt_step_reg};
                        wgt_addr[r]   = layer_wgt_base + dw_wgt_offset;
                    end
                    state_next = S_DW_WRITEBACK;
                end
            end

            S_DW_WRITEBACK: begin
                // Write SA row 0 result to psum[dw_ctile]
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

            // ------------------------------------------------------------------
            // Residual addition (same as v2 logic)
            // ------------------------------------------------------------------
            S_READ_RESIDUAL: begin
                read_res     = 1'b1;
                psum_raddr_c = c_out_tile_reg[8:0];
                // Drive c_in_out so TB serves correct residual channel from res_buf
                c_in_out     = c_out_tile_reg;
                state_next   = S_READ_RESIDUAL_WAIT;
            end

            S_READ_RESIDUAL_WAIT: begin
                read_res     = 1'b1;
                // Keep psum_raddr_c and c_in_out valid so reads complete correctly
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
                // Drive bias_addr so prelu_addr = bias_addr gives per-channel PReLU (matches v2)
                bias_addr    = bias_base_reg + {4'b0, c_out_tile_reg[9:0]};
                if (c_out_tile_reg + 1 >= layer_out_ch) begin
                    c_out_tile_next = '0;
                    state_next      = S_SPATIAL_LOOP;
                end else begin
                    c_out_tile_next = c_out_tile_reg + 1'b1;
                end
            end

            // ------------------------------------------------------------------
            S_SPATIAL_LOOP: begin
                wgt_step_next = wgt_step_reg; // hold
                if (is_global_dw) begin
                    state_next = S_NEXT_LAYER_WAIT;
                end else if (x_reg >= 9'(layer_w) - 9'(layer_stride)) begin
                    x_next = '0;
                    if (y_reg >= 9'(layer_h) - 9'(layer_stride)) begin
                        y_next = '0;
                        state_next = S_NEXT_LAYER_WAIT;
                    end else begin
                        y_next = y_reg + 9'(layer_stride);
                        state_next = layer_is_dw ? S_DW_CTILE_INIT : S_ACT_LOAD;
                        c_in_tile_next  = '0;
                        c_out_tile_next = '0;
                        dw_ctile_next   = '0;
                    end
                end else begin
                    x_next = x_reg + 9'(layer_stride);
                    state_next = layer_is_dw ? S_DW_CTILE_INIT : S_ACT_LOAD;
                    c_in_tile_next  = '0;
                    c_out_tile_next = '0;
                    dw_ctile_next   = '0;
                end
            end

            // ------------------------------------------------------------------
            S_NEXT_LAYER_WAIT: state_next = S_NEXT_LAYER;

            S_NEXT_LAYER: begin
                if (layer_idx_reg >= 6'd49) begin
                    state_next = S_DONE;
                end else begin
                    bias_base_next = bias_base_reg + {4'b0, layer_out_ch};
                    layer_idx_next = layer_idx_reg + 1'b1;
                    state_next     = S_LOAD_CFG;
                    reset_ptr      = 1'b1;
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
