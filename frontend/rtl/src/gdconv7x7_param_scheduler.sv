// Parameter scheduler for output_layer.conv_6_dw.conv.
//
// gdconv7x7_core emits one psum per output channel. quant_param_mem common
// banks have one-cycle read latency, so this module issues one common read per
// psum and delays the psum/channel metadata by the same cycle.
module gdconv7x7_param_scheduler #(
    parameter int ACC_W = 32,
    parameter int BIAS_W = 64,
    parameter int MUL_W = 32,
    parameter int SHIFT_W = 6,
    parameter int PARAM_ADDR_W = 16,
    parameter int CHANNELS = 512,

    localparam int CHANNEL_W = (CHANNELS <= 1) ? 1 : $clog2(CHANNELS)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start_i,

    input  logic [PARAM_ADDR_W-1:0] common_param_base_i,

    input  logic                    psum_valid_i,
    input  logic [CHANNEL_W-1:0]    psum_channel_i,
    input  logic signed [ACC_W-1:0] psum_i,

    output logic                    common_rd_en_o,
    output logic [PARAM_ADDR_W-1:0] common_rd_addr_o,
    input  logic                    common_rd_valid_i,
    input  logic signed [BIAS_W-1:0] param_bias_i,
    input  logic signed [MUL_W-1:0]  param_requant_multiplier_i,
    input  logic [SHIFT_W-1:0]       param_requant_shift_i,

    output logic                    valid_o,
    output logic [CHANNEL_W-1:0]    channel_o,
    output logic signed [ACC_W-1:0] psum_o,
    output logic signed [BIAS_W-1:0] bias_o,
    output logic signed [MUL_W-1:0]  requant_multiplier_o,
    output logic [SHIFT_W-1:0]       requant_shift_o
);
    logic [PARAM_ADDR_W-1:0] common_param_base_r;
    logic valid_pipe;
    logic [CHANNEL_W-1:0] channel_pipe;
    logic signed [ACC_W-1:0] psum_pipe;

    assign common_rd_en_o = psum_valid_i;
    assign common_rd_addr_o = common_param_base_r + PARAM_ADDR_W'(psum_channel_i);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            common_param_base_r <= '0;
            valid_pipe <= 1'b0;
            channel_pipe <= '0;
            psum_pipe <= '0;
        end else begin
            if (start_i) begin
                common_param_base_r <= common_param_base_i;
            end
            valid_pipe <= psum_valid_i;
            channel_pipe <= psum_channel_i;
            psum_pipe <= psum_i;
        end
    end

    assign valid_o = valid_pipe && common_rd_valid_i;
    assign channel_o = channel_pipe;
    assign psum_o = psum_pipe;
    assign bias_o = param_bias_i;
    assign requant_multiplier_o = param_requant_multiplier_i;
    assign requant_shift_o = param_requant_shift_i;

endmodule
