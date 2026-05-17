module spatial_ic_accumulator #(
    parameter int ACC_W = 32
) (
    input  logic clk,
    input  logic rst_n,

    // 0: DW mode, one PE result is already final.
    // 1: Conv3x3 mode, accumulate all input-channel partial sums.
    input  logic conv_mode_i,

    input  logic                    valid_i,
    input  logic signed [ACC_W-1:0] partial_psum_i,
    input  logic                    ic_first_i,
    input  logic                    ic_last_i,

    output logic signed [ACC_W-1:0] psum_o,
    output logic                    valid_o
);
    logic signed [ACC_W-1:0] acc_r;
    logic signed [ACC_W-1:0] psum_r;
    logic                    valid_r;

    logic signed [ACC_W-1:0] acc_base_w;
    logic signed [ACC_W-1:0] acc_sum_w;

    assign acc_base_w = ic_first_i ? '0 : acc_r;
    assign acc_sum_w  = acc_base_w + partial_psum_i;

    assign psum_o  = psum_r;
    assign valid_o = valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_r <= '0;
            psum_r <= '0;
            valid_r <= 1'b0;
        end else begin
            valid_r <= 1'b0;

            if (valid_i) begin
                if (conv_mode_i) begin
                    // One registered add per input-channel partial sum. The
                    // controller marks the final channel with ic_last_i.
                    acc_r <= acc_sum_w;
                    if (ic_last_i) begin
                        psum_r <= acc_sum_w;
                        valid_r <= 1'b1;
                    end
                end else begin
                    acc_r <= '0;
                    psum_r <= partial_psum_i;
                    valid_r <= 1'b1;
                end
            end
        end
    end

endmodule
