// ==============================================================================
// Module: mfn_mac_array
// Description: Pipelined 9-element dot product.
//   Stage 1 (registered): 9x (16-bit × 16-bit) multipliers
//   Stage 2 (combinational): adder tree → 40-bit output
// ==============================================================================

module mfn_mac_array #(
    parameter int NUM_MACS = 9,
    parameter int DWIDTH   = 16,
    parameter int AWIDTH   = 40
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic signed [DWIDTH-1:0]        act_in  [0:NUM_MACS-1],
    input  logic signed [DWIDTH-1:0]        wgt_in  [0:NUM_MACS-1],
    output logic signed [AWIDTH-1:0]        mac_out
);

    // Stage 1: Registered multiply results
    logic signed [2*DWIDTH-1:0] prod_reg [0:NUM_MACS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_MACS; i++)
                prod_reg[i] <= '0;
        end else begin
            for (int i = 0; i < NUM_MACS; i++)
                prod_reg[i] <= $signed(act_in[i]) * $signed(wgt_in[i]);
        end
    end

    // Stage 2: Combinational adder tree -> Registered Output
    logic signed [AWIDTH-1:0] mac_sum;
    always_comb begin
        mac_sum = '0;
        for (int i = 0; i < NUM_MACS; i++)
            mac_sum = mac_sum + AWIDTH'(prod_reg[i]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mac_out <= '0;
        else        mac_out <= mac_sum;
    end

endmodule
