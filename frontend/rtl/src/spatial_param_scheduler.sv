// Parameter scheduler for the spatial 3x3 stream.
//
// spatial3x3_dev emits one psum per cycle in HWC order:
//   for x
//     for y
//       for channel tile
//         lane 0..15
//
// quant_param_mem has one-cycle read latency. This scheduler issues common
// reads for every valid psum and conditionally issues PReLU/residual bank reads
// based on the locally latched layer mode.
module spatial_param_scheduler #(
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int OUT_W = 8,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,
    parameter int PARAM_ADDR_W = 16,
    parameter int FILTER_CNT_W = 10,

    localparam int MODE_W = 3
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start_i,

    input  logic [MODE_W-1:0]       post_mode_i,
    input  logic signed [OUT_W-1:0] output_zero_point_i,
    input  logic [PARAM_ADDR_W-1:0] common_param_base_i,
    input  logic [PARAM_ADDR_W-1:0] prelu_param_base_i,
    input  logic [PARAM_ADDR_W-1:0] residual_param_base_i,
    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,

    input  logic signed [ACC_W-1:0] psum_i,
    input  logic                    valid_i,
    input  logic signed [ACC_W-1:0] residual_i,

    // Global quant_param_mem bank read ports.
    output logic                    common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] common_rd_addr_o,
    input  logic                    common_rd_valid_i,
    output logic                    prelu_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] prelu_rd_addr_o,
    input  logic                    prelu_rd_valid_i,
    output logic                    residual_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] residual_rd_addr_o,
    input  logic                    residual_rd_valid_i,
    input  logic signed [BIAS_W-1:0] param_bias_i,
    input  logic signed [MUL_W-1:0] param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]      param_requant_shift_i,
    input  logic signed [MUL_W-1:0] param_prelu_multiplier_i,
    input  logic [SHIFT_W-1:0]      param_prelu_shift_i,
    input  logic signed [MUL_W-1:0] param_residual_multiplier_i,
    input  logic [SHIFT_W-1:0]      param_residual_shift_i,
    input  logic signed [BIAS_W-1:0] param_residual_zero_point_i,

    output logic signed [ACC_W-1:0] psum_o,
    output logic                    valid_o,
    output logic signed [ACC_W-1:0] residual_o,
    output logic [MODE_W-1:0]       post_mode_o,
    output logic signed [ACC_W-1:0] output_zero_point_o,
    output logic signed [BIAS_W-1:0] bias_o,
    output logic signed [MUL_W-1:0] requant_multiplier_o,
    output logic [SHIFT_W-1:0]      requant_shift_o,
    output logic signed [MUL_W-1:0] prelu_multiplier_o,
    output logic [SHIFT_W-1:0]      prelu_shift_o,
    output logic signed [MUL_W-1:0] residual_multiplier_o,
    output logic [SHIFT_W-1:0]      residual_shift_o,
    output logic signed [BIAS_W-1:0] residual_zero_point_o
);
    localparam logic [MODE_W-1:0] MODE_PRELU_REQUANT    = 3'd2;
    localparam logic [MODE_W-1:0] MODE_RESIDUAL_REQUANT = 3'd3;

    logic [FILTER_CNT_W-1:0] ch_cnt, ch_cnt_nxt;
    logic [FILTER_CNT_W-1:0] current_num_filter_r;
    logic [PARAM_ADDR_W-1:0] common_param_base_r;
    logic [PARAM_ADDR_W-1:0] prelu_param_base_r;
    logic [PARAM_ADDR_W-1:0] residual_param_base_r;
    logic [MODE_W-1:0] post_mode_r;
    logic signed [ACC_W-1:0] output_zero_point_r;
    logic signed [ACC_W-1:0] psum_pipe;
    logic signed [ACC_W-1:0] residual_pipe;
    logic [MODE_W-1:0] post_mode_pipe;
    logic signed [ACC_W-1:0] output_zero_point_pipe;
    logic valid_pipe;
    logic prelu_needed_pipe;
    logic residual_needed_pipe;
    logic wrap_channel_w;
    logic prelu_needed_w;
    logic residual_needed_w;
    logic valid_params_w;

    assign prelu_needed_w = (post_mode_r == MODE_PRELU_REQUANT);
    assign residual_needed_w = (post_mode_r == MODE_RESIDUAL_REQUANT);
    assign wrap_channel_w = (current_num_filter_r <= FILTER_CNT_W'(1)) ||
                            (ch_cnt == (current_num_filter_r - FILTER_CNT_W'(1)));
    assign valid_params_w = common_rd_valid_i &&
                            (!prelu_needed_pipe || prelu_rd_valid_i) &&
                            (!residual_needed_pipe || residual_rd_valid_i);

    always_comb begin
        ch_cnt_nxt = ch_cnt;
        if (start_i) begin
            ch_cnt_nxt = '0;
        end else if (valid_i) begin
            if (wrap_channel_w) begin
                ch_cnt_nxt = '0;
            end else begin
                ch_cnt_nxt = ch_cnt + FILTER_CNT_W'(1);
            end
        end
    end

    // One common parameter row is requested for every psum. Optional banks only
    // read when the current layer mode needs them.
    always_comb begin
        common_rd_en_o = valid_i;
        common_rd_addr_o = common_param_base_r + PARAM_ADDR_W'(ch_cnt);
        prelu_rd_en_o = valid_i && prelu_needed_w;
        prelu_rd_addr_o = prelu_param_base_r + PARAM_ADDR_W'(ch_cnt);
        residual_rd_en_o = valid_i && residual_needed_w;
        residual_rd_addr_o = residual_param_base_r + PARAM_ADDR_W'(ch_cnt);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch_cnt <= '0;
            current_num_filter_r <= '0;
            common_param_base_r <= '0;
            prelu_param_base_r <= '0;
            residual_param_base_r <= '0;
            post_mode_r <= '0;
            output_zero_point_r <= '0;
            psum_pipe <= '0;
            residual_pipe <= '0;
            post_mode_pipe <= '0;
            output_zero_point_pipe <= '0;
            valid_pipe <= 1'b0;
            prelu_needed_pipe <= 1'b0;
            residual_needed_pipe <= 1'b0;
        end else begin
            if (start_i) begin
                current_num_filter_r <= current_num_filter_i;
                common_param_base_r <= common_param_base_i;
                prelu_param_base_r <= prelu_param_base_i;
                residual_param_base_r <= residual_param_base_i;
                post_mode_r <= post_mode_i;
                output_zero_point_r <= ACC_W'(output_zero_point_i);
            end
            ch_cnt <= ch_cnt_nxt;
            psum_pipe <= psum_i;
            residual_pipe <= residual_i;
            post_mode_pipe <= post_mode_r;
            output_zero_point_pipe <= output_zero_point_r;
            valid_pipe <= valid_i;
            prelu_needed_pipe <= prelu_needed_w;
            residual_needed_pipe <= residual_needed_w;
        end
    end

    assign psum_o = psum_pipe;
    assign residual_o = residual_pipe;
    assign post_mode_o = post_mode_pipe;
    assign output_zero_point_o = output_zero_point_pipe;
    assign bias_o = param_bias_i;
    assign requant_multiplier_o = param_requant_multiplier_i;
    assign requant_shift_o = param_requant_shift_i;
    assign prelu_multiplier_o = param_prelu_multiplier_i;
    assign prelu_shift_o = param_prelu_shift_i;
    assign residual_multiplier_o = param_residual_multiplier_i;
    assign residual_shift_o = param_residual_shift_i;
    assign residual_zero_point_o = param_residual_zero_point_i;
    assign valid_o = valid_pipe && valid_params_w;

endmodule
