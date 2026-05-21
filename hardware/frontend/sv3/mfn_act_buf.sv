// =============================================================================
// mfn_act_buf.sv — Activation buffer (v3+, SRAM-macro version)
//
// Wraps the act_buf SRAM macro (sram_act_buf_1rw0r0w_192_64_freepdk45):
//   192-bit word = one 12-channel tile (12 × 16-bit), 64 words, 1RW.
//   Replaces the 512×16 FF array (post-opt④: 168 K cells) with one macro.
//
// Channel → SRAM mapping:
//   channel C  →  row = C / 12 , lane = C % 12
//   (all wide accesses use 12-aligned addresses → exact row mapping;
//    narrow accesses use the 16-bit-granular write mask.)
//
// Load (one of two modes per cycle, gated by load_en):
//   load_wide=1 : write whole 192-bit row  ← pixel_in[0..11]   (wmask=FFF)
//   load_wide=0 : write one 16-bit lane    ← pixel_in[0]       (wmask=one-hot)
//
// Read — REGISTERED, 2-cycle latency:
//   cycle N   : controller drives base_ch
//   cycle N+1 : SRAM dout0 valid (SRAM internal register)
//   cycle N+2 : act_out[0..11] valid  (wrapper output register)
//   The extra output register lets the SA see act_out as a clean posedge
//   signal for a full cycle — the OpenRAM SRAM produces dout0 on the negedge,
//   so a direct combinational use would give the SA only half a cycle.
//   → the controller MUST drive base_ch TWO cycles before the compute cycle.
//   act_out[k] is zero-padded when base_ch+k >= max_ch (partial last tile).
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
    input  logic                        load_wide,
    input  logic [$clog2(MAX_CH)-1:0]   load_ch,   // base (wide) / single (narrow)
    input  logic signed [DWIDTH-1:0]    pixel_in [SA_COLS],

    // Read port (registered: act_out valid the cycle AFTER base_ch)
    input  logic [9:0]                  max_ch,    // dynamic ceiling for zero-pad
    input  logic [$clog2(MAX_CH)-1:0]   base_ch,   // c_in_tile start (12-aligned)
    output logic signed [DWIDTH-1:0]    act_out [SA_COLS]
);
    // ── channel → (row, lane) ────────────────────────────────────────────────
    logic [5:0] wr_row, rd_row;
    logic [3:0] wr_lane;
    assign wr_row  = 6'(load_ch / 12);
    assign wr_lane = 4'(load_ch % 12);
    assign rd_row  = 6'(base_ch / 12);

    // ── SRAM control: load_en=1 → write, else → read ─────────────────────────
    logic         web0;
    logic [5:0]   addr0;
    logic [11:0]  wmask0;
    logic [191:0] din0, dout0;

    assign web0  = ~load_en;                       // 0=write, 1=read
    assign addr0 = load_en ? wr_row : rd_row;

    // Write data: wide → pack 12 lanes; narrow → replicate pixel_in[0]
    always_comb
        for (int k = 0; k < SA_COLS; k++)
            din0[k*16 +: 16] = load_wide ? pixel_in[k] : pixel_in[0];

    // Write mask: wide → all 12; narrow → one-hot at wr_lane; idle → none
    always_comb begin
        if (!load_en)       wmask0 = 12'h000;
        else if (load_wide) wmask0 = 12'hFFF;
        else                wmask0 = (12'h1 << wr_lane);
    end

    sram_act_buf_1rw0r0w_192_64_freepdk45 u_sram (
        .clk0  (clk),
        .csb0  (1'b0),       // always selected
        .web0  (web0),
        .wmask0(wmask0),
        .addr0 (addr0),
        .din0  (din0),
        .dout0 (dout0)
    );

    // ── registered read context: base_ch/max_ch delayed 1 cycle to align with
    //    dout0 (SRAM 1-cycle latency) for the zero-pad comparison ─────────────
    logic [$clog2(MAX_CH)-1:0] base_ch_d;
    logic [9:0]                max_ch_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_ch_d <= '0;
            max_ch_d  <= '0;
        end else begin
            base_ch_d <= base_ch;
            max_ch_d  <= max_ch;
        end
    end

    // ── read unpack + zero-pad (combinational from SRAM dout) ────────────────
    logic signed [DWIDTH-1:0] act_out_comb [SA_COLS];
    always_comb
        for (int c = 0; c < SA_COLS; c++) begin
            int idx;
            idx = int'(base_ch_d) + c;
            act_out_comb[c] = (idx < int'(max_ch_d)) ? dout0[c*16 +: 16] : '0;
        end

    // ── output register: act_out is a clean posedge signal → SA gets a full
    //    cycle (total read latency = 2 cycles from base_ch) ─────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            foreach (act_out[c]) act_out[c] <= '0;
        else
            foreach (act_out[c]) act_out[c] <= act_out_comb[c];
    end
endmodule
