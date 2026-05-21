// ==============================================================================
// Module: mfn_activation
// Description: Handles Post-Quantization (Shift & Clamp) then PReLU.
//   4-stage pipeline (Stage 2 split — see Stage 1+2 of the 150 MHz plan, §35):
//     Stage 0 register : input register — absorbs the psum SRAM negedge-dout
//                        launch so the downstream stage-1 logic gets a full
//                        cycle to compute.
//     Stage 1 register : shift + clamp (p_out_s0 → clamped) → clamped_s1
//     Stage 2A register: 16×16 PReLU multiply → prelu_prod_s2a (the heaviest
//                        single combinational delay in the activation path)
//     Stage 2B register: shift + MUX + residual add + clamp → output
//   valid_out is now 4 cycles after valid_in.  Side-band signals
//   (has_prelu, prelu_w, layer_is_res, residual_in, clamped) are pipelined
//   alongside p_out / valid so per-pixel timing alignment is preserved.
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
    // Stage 0 register: input register stage (new — for 150 MHz plan)
    //   Captures the psum SRAM read result and side-band signals on a
    //   posedge so the next stage-1 combinational has a full cycle.
    // ---------------------------------------------------------------
    logic                     valid_s0;
    logic signed [AWIDTH-1:0] p_out_s0;
    logic                     has_prelu_s0;
    logic signed [DWIDTH-1:0] prelu_w_s0;
    logic                     layer_is_res_s0;
    logic signed [DWIDTH-1:0] residual_s0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0        <= 1'b0;
            p_out_s0        <= '0;
            has_prelu_s0    <= 1'b0;
            prelu_w_s0      <= '0;
            layer_is_res_s0 <= 1'b0;
            residual_s0     <= '0;
        end else begin
            valid_s0        <= valid_in;
            p_out_s0        <= p_out;
            has_prelu_s0    <= has_prelu;
            prelu_w_s0      <= prelu_w;
            layer_is_res_s0 <= layer_is_res;
            residual_s0     <= residual_in;
        end
    end

    // ---------------------------------------------------------------
    // Stage 1 combinational: shift + clamp (driven from stage-0 regs)
    // ---------------------------------------------------------------
    logic signed [AWIDTH-1:0] shifted;
    logic signed [DWIDTH-1:0] clamped;

    assign shifted = p_out_s0 >>> F_BITS;

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
            has_prelu_s1    <= has_prelu_s0;
            prelu_w_s1      <= prelu_w_s0;
            layer_is_res_s1 <= layer_is_res_s0;
            residual_s1     <= residual_s0;
            valid_s1        <= valid_s0;
        end
    end

    // ---------------------------------------------------------------
    // Stage 2A combinational: 16×16 PReLU multiply (heaviest single arc)
    // ---------------------------------------------------------------
    logic signed [31:0] prelu_prod;
    assign prelu_prod = $signed(clamped_s1) * $signed(prelu_w_s1);

    // ---------------------------------------------------------------
    // Stage 2A register: registered product + sideband for stage 2B
    //   clamped_s2a is kept so stage 2B can do the (clamped < 0) MUX and the
    //   non-PReLU passthrough without re-reading clamped_s1.
    // ---------------------------------------------------------------
    logic signed [31:0]       prelu_prod_s2a;
    logic signed [DWIDTH-1:0] clamped_s2a;
    logic                     has_prelu_s2a;
    logic                     layer_is_res_s2a;
    logic signed [DWIDTH-1:0] residual_s2a;
    logic                     valid_s2a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prelu_prod_s2a   <= '0;
            clamped_s2a      <= '0;
            has_prelu_s2a    <= 1'b0;
            layer_is_res_s2a <= 1'b0;
            residual_s2a     <= '0;
            valid_s2a        <= 1'b0;
        end else begin
            prelu_prod_s2a   <= prelu_prod;
            clamped_s2a      <= clamped_s1;
            has_prelu_s2a    <= has_prelu_s1;
            layer_is_res_s2a <= layer_is_res_s1;
            residual_s2a     <= residual_s1;
            valid_s2a        <= valid_s1;
        end
    end

    // ---------------------------------------------------------------
    // Stage 2B combinational: shift + MUX + residual + clamp
    // ---------------------------------------------------------------
    logic signed [31:0]       prelu_shifted;
    logic signed [31:0]       result_raw;
    logic signed [DWIDTH-1:0] result;

    assign prelu_shifted = prelu_prod_s2a >>> F_BITS;

    always_comb begin
        if (has_prelu_s2a && (clamped_s2a < 0))
            result_raw = prelu_shifted;
        else
            result_raw = 32'(clamped_s2a);

        if (layer_is_res_s2a)
            result_raw = result_raw + 32'(residual_s2a);

        if      (result_raw > 32767)  result = 16'sd32767;
        else if (result_raw < -32768) result = -16'sd32768;
        else                          result = DWIDTH'(result_raw);
    end

    // ---------------------------------------------------------------
    // Stage 2B register: output
    // ---------------------------------------------------------------
    logic signed [DWIDTH-1:0] out_reg;
    logic                     valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg   <= '0;
            valid_reg <= 1'b0;
        end else begin
            if (valid_s2a) out_reg <= result;
            valid_reg <= valid_s2a;
        end
    end

    assign pixel_out = out_reg;
    assign valid_out = valid_reg;

endmodule
