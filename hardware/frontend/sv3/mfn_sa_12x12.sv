// =============================================================================
// mfn_sa_12x12.sv — 12×12 Output-Stationary Processing Array (v3)
//
// Dimensions:
//   SA_ROWS=12 → 12 output channels computed in parallel
//   SA_COLS=12 → 12 input channels accumulated per cycle
//
// Each compute cycle:
//   act_in[0..11]        : 12 activations broadcast to all rows
//   wgt_in[r][0..11]     : 12 weights for row r (c_out=r), from weight ROM
//   acc[r] += sum_c( act_in[c] * wgt_in[r][c] )
//
// Control:
//   clear=1             : load bias_in[r] into acc[r] (start new c_out tile)
//   enable=1            : compute one c_in tile (12 products per row → add to acc)
//   clear and enable are mutually exclusive (clear has priority)
//
// Memory interface:
//   Read: acc_out[r] valid the cycle after enable goes low
//   Write: controller reads acc_out and writes to psum SRAM sequentially
// =============================================================================

module mfn_sa_12x12 #(
    parameter int DWIDTH   = 16,
    parameter int AWIDTH   = 40,
    parameter int SA_ROWS  = 12,
    parameter int SA_COLS  = 12
)(
    input  logic                            clk,
    input  logic                            rst_n,

    // Control
    input  logic                            clear,              // load biases
    input  logic                            enable,             // MAC cycle

    // Data inputs
    input  logic signed [DWIDTH-1:0]        act_in  [SA_COLS],  // 12 activations
    input  logic signed [DWIDTH-1:0]        wgt_in  [SA_ROWS][SA_COLS], // 144 weights
    input  logic signed [AWIDTH-1:0]        bias_in [SA_ROWS],  // 12 bias values

    // Output
    output logic signed [AWIDTH-1:0]        acc_out [SA_ROWS]   // 12 partial sums
);
    // ── per-row dot-product sum (combinational) ──────────────────────────────
    logic signed [AWIDTH-1:0] row_dot [SA_ROWS];

    always_comb begin
        for (int r = 0; r < SA_ROWS; r++) begin
            logic signed [AWIDTH-1:0] s;
            s = '0;
            for (int c = 0; c < SA_COLS; c++) begin
                logic signed [2*DWIDTH-1:0] p;
                p = act_in[c] * wgt_in[r][c];
                s = s + {{(AWIDTH-2*DWIDTH){p[2*DWIDTH-1]}}, p};
            end
            row_dot[r] = s;
        end
    end

    // ── per-row accumulator register ─────────────────────────────────────────
    logic signed [AWIDTH-1:0] acc [SA_ROWS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            foreach (acc[r]) acc[r] <= '0;
        else if (clear)
            foreach (acc[r]) acc[r] <= bias_in[r];
        else if (enable)
            foreach (acc[r]) acc[r] <= acc[r] + row_dot[r];
    end

    assign acc_out = acc;
endmodule
