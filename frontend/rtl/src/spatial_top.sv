// Layer-level spatial 3x3 device.
//
// External meaning:
//   start_i starts one spatial layer.
//   done_o is asserted only after the processed output stream has been packed
//   and issued to the A/O SRAM write port.
//
// Internal meaning:
//   spatial3x3_dev.busy/done are compute-local signals. They are intentionally
//   not exposed as the layer completion handshake, because compute completion is
//   earlier than writeback completion.
module spatial_top #(
    parameter int GB_ADDR_W = 20,
    parameter int GB_DATA_W = 128,
    parameter int DATA_W = 8,
    parameter int ACC_W = 32,
    parameter int ACT_DEPTH = 1,
    parameter int WGT_DEPTH = 32,
    parameter int ELEM_CNT_W = 32,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,

    localparam int LANES = GB_DATA_W / DATA_W,
    localparam int MASK_W = LANES,
    localparam int MODE_W = 3,
    localparam int WGT_BYTE_DEPTH = LANES * WGT_DEPTH,
    localparam int WGT_RD_ADDR_W = (WGT_BYTE_DEPTH <= 1) ? 1 : $clog2(WGT_BYTE_DEPTH),
    localparam int FILTER_CNT_W = WGT_RD_ADDR_W + 1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,
    input  logic start_i,

    // Spatial layer config.
    input  logic [GB_ADDR_W-1:0] act_base_addr_i,
    input  logic [GB_ADDR_W-1:0] wgt_base_addr_i,
    input  logic [GB_ADDR_W-1:0] out_base_addr_i,
    input  logic [ELEM_CNT_W-1:0] output_elements_i,
    input  logic [1:0] num_filter_code_i,       // 0:64, 1:128, 2:256, 3:512
    input  logic [2:0] ifmap_size_code_i,       // 0:7, 1:14, 2:28, 3:56, 4:112
    input  logic stride_i,                      // 0: stride=1, 1: stride=2
    input  logic pad_i,                         // 0: valid/no pad, 1: same pad
    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,

    // Postprocess config.
    input  logic [MODE_W-1:0]       post_mode_i,
    input  logic                    residual_en_i,
    input  logic signed [ACC_W-1:0] residual_i,
    input  logic signed [MUL_W-1:0] requant_multiplier_i,
    input  logic [SHIFT_W-1:0]      requant_shift_i,
    input  logic signed [ACC_W-1:0] output_zero_point_i,
    input  logic signed [MUL_W-1:0] prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]      prelu_shift_i,

    // Global A/O SRAM read.
    output logic                    gb_act_rd_en_o,
    output logic [GB_ADDR_W-1:0]    gb_act_rd_addr_o,
    input  logic [GB_DATA_W-1:0]    gb_act_rd_data_i,

    // Global Weight SRAM read.
    output logic                    gb_wgt_rd_en_o,
    output logic [GB_ADDR_W-1:0]    gb_wgt_rd_addr_o,
    input  logic [GB_DATA_W-1:0]    gb_wgt_rd_data_i,

    // Global A/O SRAM write.
    output logic                    gb_ao_wr_valid_o,
    output logic [GB_ADDR_W-1:0]    gb_ao_wr_addr_o,
    output logic [GB_DATA_W-1:0]    gb_ao_wr_data_o,
    output logic [MASK_W-1:0]       gb_ao_wr_mask_o,

    output logic busy_o,
    output logic done_o
);
    logic signed [ACC_W-1:0] psum;
    logic psum_valid;
    logic compute_busy;
    logic compute_done;
    logic compute_done_unused;
    logic wb_busy;

    spatial3x3_dev #(
        .ADDR_W(GB_ADDR_W),
        .WORD_W(GB_DATA_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .ACT_DEPTH(ACT_DEPTH),
        .WGT_DEPTH(WGT_DEPTH)
    ) u_spatial3x3_dev (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .pad_i(pad_i),
        .current_num_filter_i(current_num_filter_i),
        .gb_act_rd_en_o(gb_act_rd_en_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_en_o(gb_wgt_rd_en_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .psum_o(psum),
        .valid_o(psum_valid),
        .busy_o(compute_busy),
        .done_o(compute_done)
    );

    spatial_wb #(
        .ACC_W(ACC_W),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W)
    ) u_spatial_wb (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .out_base_addr_i(out_base_addr_i),
        .output_elements_i(output_elements_i),
        .psum_i(psum),
        .valid_i(psum_valid),
        .post_mode_i(post_mode_i),
        .residual_en_i(residual_en_i),
        .residual_i(residual_i),
        .requant_multiplier_i(requant_multiplier_i),
        .requant_shift_i(requant_shift_i),
        .output_zero_point_i(output_zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o),
        .busy_o(wb_busy),
        .done_o(done_o)
    );

    // Layer-level busy stays high through both compute and writeback.
    assign busy_o = compute_busy || wb_busy;

    assign compute_done_unused = compute_done;

`ifndef SYNTHESIS
    initial begin
        if (GB_DATA_W % DATA_W != 0) begin
            $fatal(1, "spatial_top requires GB_DATA_W to be a multiple of DATA_W");
        end
    end
`endif
endmodule
