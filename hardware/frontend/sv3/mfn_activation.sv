// ==============================================================================
// Module: mfn_activation
// Description: Handles Post-Quantization (Shift & Clamp) then PReLU.
//   2-stage pipeline to break critical path:
//     Stage 1 register: shift + clamp (p_out → clamped)
//     Stage 2 register: PReLU multiply + MUX + residual add + clamp → output
//   Caller must extend sram_wr_addr delay to 2 cycles to match valid_out timing.
// ==============================================================================

module mfn_activation #(
    parameter int DWIDTH = 16,
    parameter int AWIDTH = 40,
    parameter int F_BITS = 10
)(
    input  logic                            clk,
    input  logic                            rst_n,

    input  logic                            valid_in,
    input  logic signed [AWIDTH-1:0]        p_out,
    input  logic                            has_prelu,
    input  logic signed [DWIDTH-1:0]        prelu_w,
    input  logic                            layer_is_res,
    input  logic signed [DWIDTH-1:0]        residual_in,

    output logic                            valid_out,
    output logic signed [DWIDTH-1:0]        pixel_out
);

    // ---------------------------------------------------------------
    // Stage 1 combinational: shift + clamp
    // ---------------------------------------------------------------
    logic signed [AWIDTH-1:0] shifted;
    logic signed [DWIDTH-1:0] clamped;

    assign shifted = p_out >>> F_BITS;

    always_comb begin
        if      (shifted > 32767)  clamped = 16'sd32767;
        else if (shifted < -32768) clamped = -16'sd32768;
        else                       clamped = DWIDTH'(shifted);
    end

    // ---------------------------------------------------------------
    // Stage 1 register: clamped value + sideband signals
    // ---------------------------------------------------------------
    logic signed [DWIDTH-1:0] clamped_s1;
    logic                     has_prelu_s1;
    logic signed [DWIDTH-1:0] prelu_w_s1;
    logic                     layer_is_res_s1;
    logic signed [DWIDTH-1:0] residual_s1;
    logic                     valid_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clamped_s1      <= '0;
            has_prelu_s1    <= 1'b0;
            prelu_w_s1      <= '0;
            layer_is_res_s1 <= 1'b0;
            residual_s1     <= '0;
            valid_s1        <= 1'b0;
        end else begin
            clamped_s1      <= clamped;
            has_prelu_s1    <= has_prelu;
            prelu_w_s1      <= prelu_w;
            layer_is_res_s1 <= layer_is_res;
            residual_s1     <= residual_in;
            valid_s1        <= valid_in;
        end
    end

    // ---------------------------------------------------------------
    // Stage 2 combinational: PReLU multiply + MUX + residual + clamp
    // ---------------------------------------------------------------
    logic signed [31:0]       prelu_prod;
    logic signed [31:0]       prelu_shifted;
    logic signed [31:0]       result_raw;
    logic signed [DWIDTH-1:0] result;

    assign prelu_prod    = $signed(clamped_s1) * $signed(prelu_w_s1);
    assign prelu_shifted = prelu_prod >>> F_BITS;

    always_comb begin
        if (has_prelu_s1 && (clamped_s1 < 0))
            result_raw = prelu_shifted;
        else
            result_raw = clamped_s1;

        if (layer_is_res_s1)
            result_raw = result_raw + residual_s1;

        if      (result_raw > 32767)  result = 16'sd32767;
        else if (result_raw < -32768) result = -16'sd32768;
        else                          result = DWIDTH'(result_raw);
    end

    // ---------------------------------------------------------------
    // Stage 2 register: output
    // ---------------------------------------------------------------
    logic signed [DWIDTH-1:0] out_reg;
    logic                     valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg   <= '0;
            valid_reg <= 1'b0;
        end else begin
            if (valid_s1) out_reg <= result;
            valid_reg <= valid_s1;
        end
    end

    assign pixel_out = out_reg;
    assign valid_out = valid_reg;

endmodule
