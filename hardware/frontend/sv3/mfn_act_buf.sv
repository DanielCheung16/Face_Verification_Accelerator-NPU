// =============================================================================
// mfn_act_buf.sv — Activation buffer for v3 PW / standard conv
//
// Loads input-channel values into a 512-deep buffer, then provides 12 values
// at a time to the SA.
//
// Load (v3+): two modes share one write strobe.
//   load_wide=1 : 12-channel-wide write — act_mem[load_ch .. load_ch+11]
//                 ← pixel_in[0..11].  Used by PW S_ACT_LOAD and DW S_DW12_FETCH
//                 (fetch 12 consecutive channels at one (x,y) per cycle).
//   load_wide=0 : narrow 1-channel write — act_mem[load_ch] ← pixel_in[0].
//                 Used by std-conv S_ACT_LOAD, global-DW S_DW_FETCH and the
//                 opt-② per-cycle preload (each maps to a distinct address,
//                 so a 12-ch wide read does not apply).
//
// Read (unchanged): combinational, SA_COLS consecutive entries from base_ch.
//   Out-of-range channels (idx >= max_ch or >= MAX_CH) return 0.
//
// MAX_CH=512 covers the widest layer (L47/L48, 512 ch).
// =============================================================================

module mfn_act_buf #(
    parameter int DWIDTH  = 16,
    parameter int SA_COLS = 12,
    parameter int MAX_CH  = 512
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Load port (1 or SA_COLS channels per cycle, see load_wide)
    input  logic                        load_en,
    input  logic                        load_wide, // 1=12-ch wide, 0=1-ch narrow
    input  logic [$clog2(MAX_CH)-1:0]   load_ch,   // base (wide) / single (narrow)
    input  logic signed [DWIDTH-1:0]    pixel_in [SA_COLS],

    // Read port (SA_COLS channels per cycle, combinational)
    input  logic [9:0]                  max_ch,    // dynamic ceiling: zero act_out[k] if base_ch+k >= max_ch
    input  logic [$clog2(MAX_CH)-1:0]   base_ch,   // c_in_tile start index
    output logic signed [DWIDTH-1:0]    act_out [SA_COLS]
);
    logic signed [DWIDTH-1:0] act_mem [0:MAX_CH-1];

    // Load
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_CH; i++) act_mem[i] <= '0;
        end else if (load_en) begin
            if (load_wide) begin
                for (int k = 0; k < SA_COLS; k++) begin
                    int widx;
                    widx = int'(load_ch) + k;
                    if (widx < MAX_CH) act_mem[widx] <= pixel_in[k];
                end
            end else begin
                act_mem[load_ch] <= pixel_in[0];
            end
        end
    end

    // Read: SA_COLS consecutive entries, zero-pad if past max_ch or MAX_CH
    always_comb
        for (int c = 0; c < SA_COLS; c++) begin
            int idx;
            idx = int'(base_ch) + c;
            act_out[c] = (idx < MAX_CH && idx < int'(max_ch)) ? act_mem[idx] : '0;
        end
endmodule
