// Writeback path for output_layer.conv_6_dw.conv.
//
// This layer is linear global depthwise convolution, so the postprocess is
// fixed to bias + requant + clamp. No PReLU/residual mode mux is needed here.
module gdconv7x7_wb #(
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int DATA_W = 8,
    parameter int GB_DATA_W = 128,
    parameter int GB_ADDR_W = 20,
    parameter int ELEM_CNT_W = 10,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,
    parameter int BIAS_SHIFT = 16,

    localparam int LANES = GB_DATA_W / DATA_W,
    localparam int MASK_W = LANES,
    localparam int VALUE_W = (BIAS_W > ACC_W) ? BIAS_W : ACC_W,
    localparam int PRODUCT_W = VALUE_W + MUL_W
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic [ELEM_CNT_W-1:0] output_elements_i,
    input  logic signed [ACC_W-1:0] output_zero_point_i,

    input  logic signed [ACC_W-1:0] psum_i,
    input  logic                    valid_i,
    input  logic signed [BIAS_W-1:0] bias_i,
    input  logic signed [MUL_W-1:0]  requant_multiplier_i,
    input  logic [SHIFT_W-1:0]       requant_shift_i,

    output logic                    gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]    gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]    gb_ao_wr_data_o,
    output logic [MASK_W-1:0]       gb_ao_wr_mask_o,

    output logic busy_o,
    output logic done_o
);
    logic signed [VALUE_W-1:0] s0_value;
    logic signed [MUL_W-1:0] s0_multiplier;
    logic [SHIFT_W-1:0] s0_shift;
    logic signed [VALUE_W-1:0] s0_output_zero_point;
    logic s0_valid;

    logic signed [PRODUCT_W-1:0] s1_product;
    logic [SHIFT_W-1:0] s1_shift;
    logic signed [VALUE_W-1:0] s1_output_zero_point;
    logic s1_valid;

    logic signed [VALUE_W-1:0] s2_value;
    logic s2_valid;

    logic signed [PRODUCT_W-1:0] round_offset_w;
    logic signed [PRODUCT_W-1:0] rounded_product_w;
    logic signed [VALUE_W-1:0] shifted_value_w;
    logic signed [VALUE_W-1:0] final_value_w;
    logic signed [DATA_W-1:0] processed_data_w;
    logic signed [VALUE_W-1:0] max_int8_w;
    logic signed [VALUE_W-1:0] min_int8_w;

    logic pack_start_r;
    logic [GB_ADDR_W-1:0] out_base_addr_r;
    logic [ELEM_CNT_W-1:0] output_elements_r;
    logic pack_busy;

    assign max_int8_w = VALUE_W'(127);
    assign min_int8_w = -VALUE_W'(128);
    assign round_offset_w = (s1_shift == '0) ? '0 :
                            (PRODUCT_W'(1) <<< (s1_shift - SHIFT_W'(1)));
    assign rounded_product_w = s1_product + round_offset_w;
    assign shifted_value_w = VALUE_W'(rounded_product_w >>> s1_shift);
    assign final_value_w = shifted_value_w + s1_output_zero_point;

    always_comb begin
        if (s2_value > max_int8_w) begin
            processed_data_w = DATA_W'(8'sh7f);
        end else if (s2_value < min_int8_w) begin
            processed_data_w = DATA_W'(8'sh80);
        end else begin
            processed_data_w = s2_value[DATA_W-1:0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_value <= '0;
            s0_multiplier <= '0;
            s0_shift <= '0;
            s0_output_zero_point <= '0;
            s0_valid <= 1'b0;
            s1_product <= '0;
            s1_shift <= '0;
            s1_output_zero_point <= '0;
            s1_valid <= 1'b0;
            s2_value <= '0;
            s2_valid <= 1'b0;
            pack_start_r <= 1'b0;
            out_base_addr_r <= '0;
            output_elements_r <= '0;
        end else begin
            if (start_i) begin
                out_base_addr_r <= out_base_addr_i;
                output_elements_r <= output_elements_i;
                pack_start_r <= 1'b1;
            end else begin
                pack_start_r <= 1'b0;
            end

            // Stage 0: move accumulator into the folded-bias fixed-point domain.
            s0_value <= (VALUE_W'(psum_i) <<< BIAS_SHIFT) + VALUE_W'(bias_i);
            s0_multiplier <= requant_multiplier_i;
            s0_shift <= requant_shift_i + SHIFT_W'(BIAS_SHIFT);
            s0_output_zero_point <= VALUE_W'(output_zero_point_i);
            s0_valid <= valid_i;

            // Stage 1: requant multiply.
            s1_product <= s0_value * s0_multiplier;
            s1_shift <= s0_shift;
            s1_output_zero_point <= s0_output_zero_point;
            s1_valid <= s0_valid;

            // Stage 2: round/shift/add zero-point. Clamp is combinational
            // before the packer and does not feed back into the multiplier path.
            s2_value <= final_value_w;
            s2_valid <= s1_valid;
        end
    end

    spatial_pack_writeback #(
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W)
    ) u_pack_writeback (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(pack_start_r),
        .out_base_addr_i(out_base_addr_r),
        .output_elements_i(output_elements_r),
        .data_i(processed_data_w),
        .valid_i(s2_valid),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o),
        .busy_o(pack_busy),
        .done_o(done_o)
    );

    assign busy_o = pack_busy;

`ifndef SYNTHESIS
    initial begin
        if (GB_DATA_W % DATA_W != 0) begin
            $fatal(1, "gdconv7x7_wb requires GB_DATA_W to be a multiple of DATA_W");
        end
    end
`endif

endmodule
