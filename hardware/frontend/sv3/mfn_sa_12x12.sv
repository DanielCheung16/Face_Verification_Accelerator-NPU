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
// Pipeline (note §35 Stage 3, 200 MHz push):
//   stage A (comb)  : act/wgt → 12 mul + adder tree → row_dot[r]
//   stage A register: row_dot_reg[r], enable_d                  (this file)
//   stage B (ff)    : acc[r] <= acc[r] + row_dot_reg[r]         (this file)
// Controller is unchanged — every COMPUTE cycle is followed by a NEXT_CIN /
// KP_NEXT cycle with enable=0, which is exactly the drain cycle this pipeline
// needs to flush row_dot_reg into acc.  Per-c_out-tile cycle count unchanged.
//
// Memory interface:
//   Read: acc_out[r] valid the cycle after the drain (i.e. when WRITEBACK starts)
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
    // dw_mode=1: acc[r] += act_in[r] * wgt_in[r][0]  (DW 12-ch parallel)
    // dw_mode=0: acc[r] += Σ_c act_in[c]*wgt_in[r][c] (PW / std-conv)
    input  logic                            dw_mode,

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
            if (dw_mode) begin
                // DW 12-ch parallel: each row uses its own activation (diagonal)
                automatic logic signed [2*DWIDTH-1:0] p;
                p = act_in[r] * wgt_in[r][0];
                row_dot[r] = {{(AWIDTH-2*DWIDTH){p[2*DWIDTH-1]}}, p};
            end else begin
                automatic logic signed [AWIDTH-1:0] s;
                s = '0;
                for (int c = 0; c < SA_COLS; c++) begin
                    automatic logic signed [2*DWIDTH-1:0] p;
                    p = act_in[c] * wgt_in[r][c];
                    s = s + {{(AWIDTH-2*DWIDTH){p[2*DWIDTH-1]}}, p};
                end
                row_dot[r] = s;
            end
        end
    end

    // ── stage A → stage B register: 12 × 40-bit row_dot + 1-bit enable ──────
    // Splits the 16×16 mult + 12-tap adder tree away from the final +acc add.
    // 480 FF added (vs ~86k total) — clear stays unregistered so bias loads
    // still take effect immediately (no race because controller's
    // S_BIAS_LOAD never follows S_*_COMPUTE directly).
    logic signed [AWIDTH-1:0] row_dot_reg [SA_ROWS];
    logic                     enable_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            foreach (row_dot_reg[r]) row_dot_reg[r] <= '0;
            enable_d <= 1'b0;
        end else begin
            enable_d <= enable;
            if (enable)
                foreach (row_dot_reg[r]) row_dot_reg[r] <= row_dot[r];
        end
    end

    // ── per-row accumulator register (stage B) ───────────────────────────────
    logic signed [AWIDTH-1:0] acc [SA_ROWS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            foreach (acc[r]) acc[r] <= '0;
        else if (clear)
            foreach (acc[r]) acc[r] <= bias_in[r];
        else if (enable_d)
            foreach (acc[r]) acc[r] <= acc[r] + row_dot_reg[r];
    end

    assign acc_out = acc;
endmodule
