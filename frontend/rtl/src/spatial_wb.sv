// Spatial 3x3 writeback path.
//
// Boundary:
//   previous stage: signed int32 psum stream from spatial3x3_dev
//   next stage:    activation/output global buffer write port
module spatial_wb #(
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int DATA_W = 8,
    parameter int GB_DATA_W = 128,
    parameter int GB_ADDR_W = 20,
    parameter int ELEM_CNT_W = 32,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,

    localparam int MASK_W = GB_DATA_W / DATA_W,
    localparam int MODE_W = 3
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic [ELEM_CNT_W-1:0] output_elements_i,

    // Stream from spatial3x3_dev.
    input  logic signed [ACC_W-1:0] psum_i,
    input  logic                    valid_i,

    // small_output_process mode:
    //   0 bypass saturate, 1 requant, 2 PReLU+requant, 3 residual+requant.
    input  logic [MODE_W-1:0]       post_mode_i,
    input  logic                    residual_en_i,
    input  logic signed [ACC_W-1:0] residual_i,
    input  logic signed [BIAS_W-1:0] bias_i,
    input  logic signed [MUL_W-1:0] residual_multiplier_i,
    input  logic [SHIFT_W-1:0]      residual_shift_i,
    input  logic signed [BIAS_W-1:0] residual_zero_point_i,
    input  logic signed [MUL_W-1:0] requant_multiplier_i,
    input  logic [SHIFT_W-1:0]      requant_shift_i,
    input  logic signed [ACC_W-1:0] output_zero_point_i,
    input  logic signed [MUL_W-1:0] prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]      prelu_shift_i,

    // Global activation/output buffer write.
    output logic                    gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]    gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]    gb_ao_wr_data_o,
    output logic [MASK_W-1:0]       gb_ao_wr_mask_o,

    output logic busy_o,
    output logic done_o
);
    logic signed [DATA_W-1:0] processed_data;
    logic processed_valid;
    logic pack_busy;
    logic [GB_ADDR_W-1:0] out_base_addr_r;
    logic [ELEM_CNT_W-1:0] output_elements_r;
    logic pack_start_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_base_addr_r <= '0;
            output_elements_r <= '0;
            pack_start_r <= 1'b0;
        end else if (start_i) begin
            out_base_addr_r <= out_base_addr_i;
            output_elements_r <= output_elements_i;
            pack_start_r <= 1'b1;
        end else begin
            pack_start_r <= 1'b0;
        end
    end

    small_output_process #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .DATA_W(DATA_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W)
    ) u_small_output_process (
        .clk(clk),
        .rst_n(rst_n),
        .psum_i(psum_i),
        .valid_i(valid_i),
        .mode_i(post_mode_i),
        .residual_en_i(residual_en_i),
        .residual_i(residual_i),
        .bias_i(bias_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .requant_multiplier_i(requant_multiplier_i),
        .requant_shift_i(requant_shift_i),
        .output_zero_point_i(output_zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .data_o(processed_data),
        .valid_o(processed_valid)
    );

    spatial_pack_writeback #(
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W)
    ) u_spatial_pack_writeback (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(pack_start_r),
        .out_base_addr_i(out_base_addr_r),
        .output_elements_i(output_elements_r),
        .data_i(processed_data),
        .valid_i(processed_valid),
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
            $fatal(1, "spatial_wb requires GB_DATA_W to be a multiple of DATA_W");
        end
    end
`endif
endmodule
