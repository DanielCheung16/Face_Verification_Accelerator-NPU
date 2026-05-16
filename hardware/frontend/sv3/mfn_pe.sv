// =============================================================================
// mfn_pe.sv — Single Processing Element for v3 12×12 Systolic Array
//
// Output-stationary design:
//   - Each PE holds one output channel's accumulator (acc)
//   - Every compute cycle: acc += act_in * wgt_in
//   - clear=1 loads bias_in into acc (starts a new spatial/c_out tile)
//
// Bit widths:
//   DWIDTH=16: activation & weight (Q5.10 fixed-point, same as v2)
//   AWIDTH=40: accumulator (same as psum SRAM width)
//   Product: 32-bit signed, sign-extended to 40-bit before accumulation
// =============================================================================

module mfn_pe #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 40
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear,     // load bias_in → acc
    input  logic                       enable,    // accumulate this cycle
    input  logic signed [DWIDTH-1:0]   act_in,    // one activation value
    input  logic signed [DWIDTH-1:0]   wgt_in,    // one weight value
    input  logic signed [AWIDTH-1:0]   bias_in,   // loaded when clear=1
    output logic signed [AWIDTH-1:0]   acc_out    // accumulated partial sum
);
    logic signed [AWIDTH-1:0]     acc;
    logic signed [2*DWIDTH-1:0]   product;

    assign product = act_in * wgt_in;   // 32-bit signed

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= '0;
        else if (clear)
            acc <= bias_in;
        else if (enable)
            acc <= acc + {{(AWIDTH - 2*DWIDTH){product[2*DWIDTH-1]}}, product};
    end

    assign acc_out = acc;
endmodule
