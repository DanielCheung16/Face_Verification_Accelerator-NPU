// ==============================================================================
// Module: mfn_mac_array
// Description: Multiplier-Accumulator Array for MobileFaceNet Convolution.
//              Contains a 9-multiplier array (for 3x3 Conv or parallel 1x1).
//              Follows Two-Process Methodology.
// ==============================================================================

module mfn_mac_array #(
    parameter int NUM_MACS = 9,
    parameter int DWIDTH   = 16,
    parameter int AWIDTH   = 32
)(
    input  logic                            clk,
    input  logic                            rst_n,
    
    input  logic                            valid_in,
    input  logic signed [DWIDTH-1:0]        act_in  [0:NUM_MACS-1], // Activations (Feature Map)
    input  logic signed [DWIDTH-1:0]        wgt_in  [0:NUM_MACS-1], // Weights
    input  logic signed [AWIDTH-1:0]        bias_in,                // Bias (used when clear_acc=1)
    input  logic                            clear_acc,              // 1: Restart accumulation, 0: Keep accumulating
    
    output logic                            valid_out,
    output logic signed [AWIDTH-1:0]        mac_out                 // Accumulated Output
);

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals (Two-Process Methodology)
    // --------------------------------------------------------------------------
    logic signed [AWIDTH-1:0] acc_reg, acc_next;
    logic                     valid_reg, valid_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic (Next State & Datapath)
    // --------------------------------------------------------------------------
    always_comb begin
        // 1. Compute Dot Product (Multiplier Array + Adder Tree)
        automatic logic signed [AWIDTH-1:0] dot_prod = '0;
        
        for (int i = 0; i < NUM_MACS; i++) begin
            // Cast to AWIDTH to prevent overflow during multiplication
            dot_prod += signed'(AWIDTH'(act_in[i])) * signed'(AWIDTH'(wgt_in[i]));
        end
        
        // 2. Accumulator Logic
        if (valid_in) begin
            if (clear_acc) begin
                // New convolution window / channel: Load Bias + Dot Product
                acc_next = bias_in + dot_prod;
            end else begin
                // Accumulating across input channels
                acc_next = acc_reg + dot_prod;
            end
        end else begin
            // Hold value if no valid input
            acc_next = acc_reg;
        end
        
        // 3. Valid signal propagation
        valid_next = valid_in;
    end

    // --------------------------------------------------------------------------
    // Process 2: Sequential Logic (Update Registers)
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg   <= '0;
            valid_reg <= 1'b0;
        end else begin
            acc_reg   <= acc_next;
            valid_reg <= valid_next;
        end
    end

    // --------------------------------------------------------------------------
    // Output Assignment
    // --------------------------------------------------------------------------
    assign mac_out   = acc_reg;
    assign valid_out = valid_reg;

endmodule
