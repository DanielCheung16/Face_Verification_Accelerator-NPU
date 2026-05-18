module spatial_ic_accumulator #(
    parameter int ACC_W = 32,
    parameter int FILTER_CNT_W = 10,
    parameter int LANES = 16
) (
    input  logic clk,
    input  logic rst_n,

    // 0: DW mode, one PE result is already final.
    // 1: Conv3x3 mode, accumulate all input-channel partial sums.
    input  logic conv_mode_i,
    input  logic start_i,
    input  logic [FILTER_CNT_W-1:0] input_channel_count_i,

    input  logic                    valid_i,
    input  logic signed [ACC_W-1:0] partial_psum_i,

    output logic signed [ACC_W-1:0] psum_o,
    output logic                    valid_o
);
    localparam int LANE_CNT_W = $clog2(LANES);

    logic signed [ACC_W-1:0] acc_r [LANES];
    logic signed [ACC_W-1:0] psum_r;
    logic                    valid_r;
    logic [LANE_CNT_W-1:0]   lane_cnt;
    logic [LANE_CNT_W-1:0]   lane_cnt_nxt;
    logic [FILTER_CNT_W-1:0] ic_cnt;
    logic [FILTER_CNT_W-1:0] ic_cnt_nxt;

    logic signed [ACC_W-1:0] acc_base_w;
    logic signed [ACC_W-1:0] acc_sum_w;
    logic lane_last_w;
    logic ic_first_w;
    logic ic_last_w;

    assign lane_last_w = (lane_cnt == LANE_CNT_W'(LANES - 1));
    assign ic_first_w = (ic_cnt == '0);
    assign ic_last_w = (input_channel_count_i <= FILTER_CNT_W'(1)) ||
                       ((ic_cnt + FILTER_CNT_W'(1)) >= input_channel_count_i);
    assign acc_base_w = ic_first_w ? '0 : acc_r[lane_cnt];
    assign acc_sum_w  = acc_base_w + partial_psum_i;
    assign lane_cnt_nxt = lane_last_w ? '0 : (lane_cnt + LANE_CNT_W'(1));
    assign ic_cnt_nxt = lane_last_w ? (ic_last_w ? '0 : (ic_cnt + FILTER_CNT_W'(1))) :
                        ic_cnt;

    // DWConv3x3 already produces a final psum per PE result. Keep this path as
    // a timing-compatible bypass; only traditional Conv3x3 uses accumulation.
    assign psum_o  = conv_mode_i ? psum_r  : partial_psum_i;
    assign valid_o = conv_mode_i ? valid_r : valid_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_r <= '0;
            valid_r <= 1'b0;
            lane_cnt <= '0;
            ic_cnt <= '0;
            for (int lane = 0; lane < LANES; lane++) begin
                acc_r[lane] <= '0;
            end
        end else begin
            valid_r <= 1'b0;

            if (start_i) begin
                lane_cnt <= '0;
                ic_cnt <= '0;
            end else if (valid_i) begin
                if (conv_mode_i) begin
                    // Conv3x3 stream order is IC-slice first, then output
                    // channel lanes. Count that order locally so the
                    // controller does not need to drive ic_first/ic_last.
                    acc_r[lane_cnt] <= acc_sum_w;
                    if (ic_last_w) begin
                        psum_r <= acc_sum_w;
                        valid_r <= 1'b1;
                    end
                    lane_cnt <= lane_cnt_nxt;
                    ic_cnt <= ic_cnt_nxt;
                end else begin
                    psum_r <= partial_psum_i;
                    valid_r <= 1'b1;
                    lane_cnt <= '0;
                    ic_cnt <= '0;
                end
            end
        end
    end

endmodule
