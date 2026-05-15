module spatial3x3_pe_array #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32,

    localparam int PRODUCT_W = DATA_W * 2
) (
    input  logic clk,
    input  logic rst_n,

    // One-cycle input valid for a complete 3x3 dot-product.
    input  logic enable_i,

    input  logic signed [DATA_W-1:0] activation_i [9],
    input  logic signed [DATA_W-1:0] weight_i     [9],

    output logic signed [ACC_W-1:0] psum_o,
    output logic                    valid_o
);
    logic signed [PRODUCT_W-1:0] product_w [9];

    logic signed [ACC_W-1:0] product_r [9];
    logic signed [ACC_W-1:0] sum_l1_r  [5];
    logic signed [ACC_W-1:0] sum_l2_r  [3];
    logic signed [ACC_W-1:0] sum_l3_r  [2];
    logic signed [ACC_W-1:0] psum_r;
    logic [4:0] valid_pipe_r;

    assign psum_o  = psum_r;
    assign valid_o = valid_pipe_r[4];

    always_comb begin
        for (int i = 0; i < 9; i++) begin
            product_w[i] = activation_i[i] * weight_i[i];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe_r <= '0;
            psum_r <= '0;
            for (int i = 0; i < 9; i++) begin
                product_r[i] <= '0;
            end
            for (int i = 0; i < 5; i++) begin
                sum_l1_r[i] <= '0;
            end
            for (int i = 0; i < 3; i++) begin
                sum_l2_r[i] <= '0;
            end
            for (int i = 0; i < 2; i++) begin
                sum_l3_r[i] <= '0;
            end
        end else begin
            valid_pipe_r <= {valid_pipe_r[3:0], enable_i};

            // Stage 1: register all 9 signed 8x8 products.
            for (int i = 0; i < 9; i++) begin
                product_r[i] <= {{(ACC_W-PRODUCT_W){product_w[i][PRODUCT_W-1]}}, product_w[i]};
            end

            // Stage 2: first adder-tree level, 9 values -> 5 values.
            sum_l1_r[0] <= product_r[0] + product_r[1];
            sum_l1_r[1] <= product_r[2] + product_r[3];
            sum_l1_r[2] <= product_r[4] + product_r[5];
            sum_l1_r[3] <= product_r[6] + product_r[7];
            sum_l1_r[4] <= product_r[8];

            // Stage 3: second adder-tree level, 5 values -> 3 values.
            sum_l2_r[0] <= sum_l1_r[0] + sum_l1_r[1];
            sum_l2_r[1] <= sum_l1_r[2] + sum_l1_r[3];
            sum_l2_r[2] <= sum_l1_r[4];

            // Stage 4: third adder-tree level, 3 values -> 2 values.
            sum_l3_r[0] <= sum_l2_r[0] + sum_l2_r[1];
            sum_l3_r[1] <= sum_l2_r[2];

            // Stage 5: final 3x3 dot-product.
            psum_r <= sum_l3_r[0] + sum_l3_r[1];
        end
    end
endmodule
