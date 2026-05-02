// ==============================================================================
// Module: mfn_activation
// Description: Handles PReLU and Post-Quantization (Shift & Clamp)
//              Formula: 
//                if do_prelu:
//                   x = (mac_in >= 0) ? mac_in : (mac_in * prelu_weight) >> 10
//                else:
//                   x = mac_in
//                out = clamp_to_int16(x >> 10)
//              Follows Two-Process Methodology.
// ==============================================================================

module mfn_activation #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 32,
    parameter int F_BITS = 10
)(
    input  logic                            clk,
    input  logic                            rst_n,
    
    input  logic                            valid_in,
    input  logic signed [AWIDTH-1:0]        mac_in,
    input  logic                            do_prelu,
    input  logic signed [DWIDTH-1:0]        prelu_weight,
    
    output logic                            valid_out,
    output logic signed [DWIDTH-1:0]        act_out
);

    // --------------------------------------------------------------------------
    // Registers & Next-State Signals
    // --------------------------------------------------------------------------
    logic signed [DWIDTH-1:0] act_reg, act_next;
    logic                     valid_reg, valid_next;

    // --------------------------------------------------------------------------
    // Process 1: Combinational Logic
    // --------------------------------------------------------------------------
    always_comb begin
        automatic logic signed [AWIDTH-1:0] prelu_out;
        automatic logic signed [AWIDTH-1:0] shifted_out;
        
        // 1. PReLU Logic
        if (do_prelu && (mac_in < 0)) begin
            // Cast to 48-bit to prevent overflow during multiplication, then shift back
            automatic logic signed [47:0] prelu_prod = signed'(48'(mac_in)) * signed'(48'(prelu_weight));
            prelu_out = AWIDTH'(prelu_prod >>> F_BITS);
        end else begin
            prelu_out = mac_in;
        end
        
        // 2. Post-Quantization Right Shift
        shifted_out = prelu_out >>> F_BITS;
        
        // 3. Clamping to INT16
        if (valid_in) begin
            if (shifted_out > 32767) begin
                act_next = 16'sd32767;
            end else if (shifted_out < -32768) begin
                act_next = -16'sd32768;
            end else begin
                act_next = DWIDTH'(shifted_out);
            end
        end else begin
            act_next = act_reg;
        end
        
        valid_next = valid_in;
    end

    // --------------------------------------------------------------------------
    // Process 2: Sequential Logic
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_reg   <= '0;
            valid_reg <= 1'b0;
        end else begin
            act_reg   <= act_next;
            valid_reg <= valid_next;
        end
    end

    // --------------------------------------------------------------------------
    // Output Assignment
    // --------------------------------------------------------------------------
    assign act_out   = act_reg;
    assign valid_out = valid_reg;

endmodule
