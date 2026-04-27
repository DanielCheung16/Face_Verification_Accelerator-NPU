// ==============================================================================
// Module: mfn_activation
// Description: Handles Post-Quantization (Shift & Clamp) then PReLU.
//   Order matches c_model_fixed: first quantize Q20->Q10, then PReLU on Q10.
//   Uses 16x16=32-bit multiplier (synthesis friendly).
// ==============================================================================

module mfn_activation #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 40,
    parameter int F_BITS = 10
)(
    input  logic                            clk,
    input  logic                            rst_n,
    
    input  logic                            valid_in,
    input  logic signed [AWIDTH-1:0]        p_out,      // Q20 accumulator
    input  logic                            has_prelu,
    input  logic signed [DWIDTH-1:0]        prelu_w,    // Q10 PReLU alpha
    
    output logic                            valid_out,
    output logic signed [DWIDTH-1:0]        pixel_out
);

    logic signed [DWIDTH-1:0] out_reg;
    logic                     valid_reg;
    
    // Combinational intermediate signals
    logic signed [AWIDTH-1:0] shifted;
    logic signed [DWIDTH-1:0] clamped;
    logic signed [31:0]       prelu_prod;
    logic signed [31:0]       prelu_shifted;
    logic signed [DWIDTH-1:0] result;

    // Step 1: Quantize Q20 -> Q10
    assign shifted = p_out >>> F_BITS;

    // Step 2: Clamp to int16
    always_comb begin
        if (shifted > 32767)       clamped = 16'sd32767;
        else if (shifted < -32768) clamped = -16'sd32768;
        else                       clamped = DWIDTH'(shifted);
    end

    // Step 3: PReLU multiply (16x16 = 32-bit, matching c_model_fixed)
    assign prelu_prod    = $signed(clamped) * $signed(prelu_w);  // Q10 * Q10 = Q20
    assign prelu_shifted = prelu_prod >>> F_BITS;                // Q20 >> 10 = Q10

    // Step 4: Select result
    always_comb begin
        if (has_prelu && (clamped < 0)) begin
            // Clamp PReLU result
            if (prelu_shifted > 32767)       result = 16'sd32767;
            else if (prelu_shifted < -32768) result = -16'sd32768;
            else                             result = DWIDTH'(prelu_shifted);
        end else begin
            result = clamped;
        end
    end

    // Registered output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg   <= '0;
            valid_reg <= 1'b0;
        end else begin
            if (valid_in)
                out_reg <= result;
            valid_reg <= valid_in;
        end
    end

    assign pixel_out = out_reg;
    assign valid_out = valid_reg;

endmodule
