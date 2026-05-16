// =============================================================================
// mfn_act_buf.sv — Activation buffer for v3 PW / standard conv
//
// Loads up to MAX_CH input-channel values one per cycle (from pixel_in),
// then provides 12 values at a time to the SA.
//
// Usage:
//   Phase 1 – LOAD:  load_en=1, load_ch increments externally 0..in_ch-1
//             Each cycle: buf[load_ch] ← pixel_in
//   Phase 2 – READ:  read_en=1, base_ch set to c_in_tile start
//             Combinational: act_out[0..11] = buf[base_ch .. base_ch+11]
//             Out-of-range channels return 0 (padding for last tile).
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

    // Load port (one channel per cycle)
    input  logic                        load_en,
    input  logic [$clog2(MAX_CH)-1:0]   load_ch,
    input  logic signed [DWIDTH-1:0]    pixel_in,

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
        end else if (load_en)
            act_mem[load_ch] <= pixel_in;
    end

    // Read: SA_COLS consecutive entries, zero-pad if past max_ch or MAX_CH
    always_comb
        for (int c = 0; c < SA_COLS; c++) begin
            int idx;
            idx = int'(base_ch) + c;
            act_out[c] = (idx < MAX_CH && idx < int'(max_ch)) ? act_mem[idx] : '0;
        end
endmodule
