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
    parameter int OUT_W = DATA_W,
    parameter int ACC_W = 32,
    parameter int ACT_DEPTH = 1,
    parameter int WGT_DEPTH = 32,
    parameter int ELEM_CNT_W = 32,
    parameter int BIAS_W = 64,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,
    parameter int PARAM_ADDR_W = 16,

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
    input  logic [PARAM_ADDR_W-1:0] bias_base_i,
    input  logic [PARAM_ADDR_W-1:0] requant_mult_base_i,
    input  logic [PARAM_ADDR_W-1:0] requant_shift_base_i,
    input  logic [PARAM_ADDR_W-1:0] prelu_mult_base_i,
    input  logic [PARAM_ADDR_W-1:0] prelu_shift_base_i,
    input  logic [PARAM_ADDR_W-1:0] residual_mult_base_i,
    input  logic [PARAM_ADDR_W-1:0] residual_shift_base_i,
    input  logic [PARAM_ADDR_W-1:0] residual_zero_point_base_i,
    input  logic [1:0] num_filter_code_i,       // 0:64, 1:128, 2:256, 3:512
    input  logic [2:0] ifmap_size_code_i,       // 0:7, 1:14, 2:28, 3:56, 4:112
    input  logic stride_i,                      // 0: stride=1, 1: stride=2
    input  logic pad_i,                         // 0: valid/no pad, 1: same pad
    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,

    // Postprocess config.
    input  logic [MODE_W-1:0]       post_mode_i,
    input  logic                    residual_en_i,
    input  logic signed [ACC_W-1:0] residual_i,
    input  logic signed [ACC_W-1:0] output_zero_point_i,

    // Global quant parameter memory reads. The scheduler issues one common
    // read for every psum and only enables PReLU/residual banks when the layer
    // mode needs them.
    output logic                    quant_common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] quant_common_rd_addr_o,
    input  logic                    quant_common_rd_valid_i,
    output logic                    quant_prelu_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] quant_prelu_rd_addr_o,
    input  logic                    quant_prelu_rd_valid_i,
    output logic                    quant_residual_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] quant_residual_rd_addr_o,
    input  logic                    quant_residual_rd_valid_i,
    input  logic signed [BIAS_W-1:0] quant_param_bias_i,
    input  logic signed [MUL_W-1:0] quant_param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]      quant_param_requant_shift_i,
    input  logic signed [MUL_W-1:0] quant_param_prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]      quant_param_prelu_shift_i,
    input  logic signed [MUL_W-1:0] quant_param_residual_multiplier_i,
    input  logic [SHIFT_W-1:0]      quant_param_residual_shift_i,
    input  logic signed [BIAS_W-1:0] quant_param_residual_zero_point_i,

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
    logic signed [ACC_W-1:0] post_psum;
    logic post_valid;
    logic signed [ACC_W-1:0] post_residual;
    logic [MODE_W-1:0] post_mode;
    logic signed [ACC_W-1:0] post_output_zero_point;
    logic signed [BIAS_W-1:0] post_bias;
    logic signed [MUL_W-1:0] post_requant_multiplier;
    logic [SHIFT_W-1:0] post_requant_shift;
    logic signed [MUL_W-1:0] post_prelu_multiplier;
    logic [SHIFT_W-1:0] post_prelu_shift;
    logic signed [MUL_W-1:0] post_residual_multiplier;
    logic [SHIFT_W-1:0] post_residual_shift;
    logic signed [BIAS_W-1:0] post_residual_zero_point;
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

    // Spatial stream parameter scheduler: converts HWC channel order into one
    // quant_param_mem read per psum and aligns params to the psum stream.
    spatial_param_scheduler #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .FILTER_CNT_W(FILTER_CNT_W)
    ) u_spatial_param_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .post_mode_i(post_mode_i),
        .output_zero_point_i(output_zero_point_i[OUT_W-1:0]),
        .common_param_base_i(bias_base_i),
        .prelu_param_base_i(prelu_mult_base_i),
        .residual_param_base_i(residual_mult_base_i),
        .current_num_filter_i(current_num_filter_i),
        .psum_i(psum),
        .valid_i(psum_valid),
        .residual_i(residual_i),
        .common_rd_en_o(quant_common_rd_en_o),
        .common_rd_addr_o(quant_common_rd_addr_o),
        .common_rd_valid_i(quant_common_rd_valid_i),
        .prelu_rd_en_o(quant_prelu_rd_en_o),
        .prelu_rd_addr_o(quant_prelu_rd_addr_o),
        .prelu_rd_valid_i(quant_prelu_rd_valid_i),
        .residual_rd_en_o(quant_residual_rd_en_o),
        .residual_rd_addr_o(quant_residual_rd_addr_o),
        .residual_rd_valid_i(quant_residual_rd_valid_i),
        .param_bias_i(quant_param_bias_i),
        .param_requant_multiplier_i(quant_param_requant_multiplier_i),
        .param_requant_shift_i(quant_param_requant_shift_i),
        .param_prelu_multiplier_i(quant_param_prelu_multiplier_i),
        .param_prelu_shift_i(quant_param_prelu_shift_i),
        .param_residual_multiplier_i(quant_param_residual_multiplier_i),
        .param_residual_shift_i(quant_param_residual_shift_i),
        .param_residual_zero_point_i(quant_param_residual_zero_point_i),
        .psum_o(post_psum),
        .valid_o(post_valid),
        .residual_o(post_residual),
        .post_mode_o(post_mode),
        .output_zero_point_o(post_output_zero_point),
        .bias_o(post_bias),
        .requant_multiplier_o(post_requant_multiplier),
        .requant_shift_o(post_requant_shift),
        .prelu_multiplier_o(post_prelu_multiplier),
        .prelu_shift_o(post_prelu_shift),
        .residual_multiplier_o(post_residual_multiplier),
        .residual_shift_o(post_residual_shift),
        .residual_zero_point_o(post_residual_zero_point)
    );

    spatial_wb #(
        .ACC_W(ACC_W),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W),
        .BIAS_W(BIAS_W)
    ) u_spatial_wb (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .out_base_addr_i(out_base_addr_i),
        .output_elements_i(output_elements_i),
        .psum_i(post_psum),
        .valid_i(post_valid),
        .post_mode_i(post_mode),
        .residual_en_i(residual_en_i),
        .residual_i(post_residual),
        .bias_i(post_bias),
        .residual_multiplier_i(post_residual_multiplier),
        .residual_shift_i(post_residual_shift),
        .residual_zero_point_i(post_residual_zero_point),
        .requant_multiplier_i(post_requant_multiplier),
        .requant_shift_i(post_requant_shift),
        .output_zero_point_i(post_output_zero_point),
        .prelu_multiplier_i(post_prelu_multiplier),
        .prelu_shift_i(post_prelu_shift),
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

    always_ff @(posedge clk) begin
        if (rst_n && start_i) begin
            if ((requant_mult_base_i !== bias_base_i) ||
                (requant_shift_base_i !== bias_base_i)) begin
                $fatal(1, "spatial_top requires aligned common parameter bases");
            end
            if (prelu_shift_base_i !== prelu_mult_base_i) begin
                $fatal(1, "spatial_top requires aligned PReLU parameter bases");
            end
            if ((residual_shift_base_i !== residual_mult_base_i) ||
                (residual_zero_point_base_i !== residual_mult_base_i)) begin
                $fatal(1, "spatial_top requires aligned residual parameter bases");
            end
        end
    end
`endif
endmodule
