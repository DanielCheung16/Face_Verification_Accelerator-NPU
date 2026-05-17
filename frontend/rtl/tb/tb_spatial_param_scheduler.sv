`timescale 1ns/1ps

module tb_spatial_param_scheduler;
    localparam int ACC_W = 32;
    localparam int BIAS_W = 64;
    localparam int OUT_W = 8;
    localparam int MUL_W = 32;
    localparam int SHIFT_W = 6;
    localparam int PARAM_ADDR_W = 8;
    localparam int FILTER_CNT_W = 4;
    localparam int HALF_CYCLE_TIME = 5;

    logic clk;
    logic rst_n;
    logic start_i;
    logic [2:0] post_mode_i;
    logic signed [OUT_W-1:0] output_zero_point_i;
    logic [PARAM_ADDR_W-1:0] param_base_i;
    logic [FILTER_CNT_W-1:0] current_num_filter_i;
    logic signed [ACC_W-1:0] psum_i;
    logic valid_i;
    logic signed [ACC_W-1:0] residual_i;
    logic param_rd_en_o;
    logic [PARAM_ADDR_W-1:0] param_rd_addr_o;
    logic param_rd_valid_i;
    logic signed [BIAS_W-1:0] param_bias_i;
    logic signed [MUL_W-1:0] param_requant_multiplier_i;
    logic [SHIFT_W-1:0] param_requant_shift_i;
    logic signed [MUL_W-1:0] param_prelu_multiplier_i;
    logic [SHIFT_W-1:0] param_prelu_shift_i;
    logic signed [MUL_W-1:0] param_residual_multiplier_i;
    logic [SHIFT_W-1:0] param_residual_shift_i;
    logic signed [BIAS_W-1:0] param_residual_zero_point_i;
    logic signed [ACC_W-1:0] psum_o;
    logic valid_o;
    logic signed [ACC_W-1:0] residual_o;
    logic [2:0] post_mode_o;
    logic signed [ACC_W-1:0] output_zero_point_o;
    logic signed [BIAS_W-1:0] bias_o;
    logic signed [MUL_W-1:0] requant_multiplier_o;
    logic [SHIFT_W-1:0] requant_shift_o;
    logic signed [MUL_W-1:0] prelu_multiplier_o;
    logic [SHIFT_W-1:0] prelu_shift_o;
    logic signed [MUL_W-1:0] residual_multiplier_o;
    logic [SHIFT_W-1:0] residual_shift_o;
    logic signed [BIAS_W-1:0] residual_zero_point_o;

    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_param_scheduler #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MUL_W(MUL_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .FILTER_CNT_W(FILTER_CNT_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .post_mode_i(post_mode_i),
        .output_zero_point_i(output_zero_point_i),
        .param_base_i(param_base_i),
        .current_num_filter_i(current_num_filter_i),
        .psum_i(psum_i),
        .valid_i(valid_i),
        .residual_i(residual_i),
        .param_rd_en_o(param_rd_en_o),
        .param_rd_addr_o(param_rd_addr_o),
        .param_rd_valid_i(param_rd_valid_i),
        .param_bias_i(param_bias_i),
        .param_requant_multiplier_i(param_requant_multiplier_i),
        .param_requant_shift_i(param_requant_shift_i),
        .param_prelu_multiplier_i(param_prelu_multiplier_i),
        .param_prelu_shift_i(param_prelu_shift_i),
        .param_residual_multiplier_i(param_residual_multiplier_i),
        .param_residual_shift_i(param_residual_shift_i),
        .param_residual_zero_point_i(param_residual_zero_point_i),
        .psum_o(psum_o),
        .valid_o(valid_o),
        .residual_o(residual_o),
        .post_mode_o(post_mode_o),
        .output_zero_point_o(output_zero_point_o),
        .bias_o(bias_o),
        .requant_multiplier_o(requant_multiplier_o),
        .requant_shift_o(requant_shift_o),
        .prelu_multiplier_o(prelu_multiplier_o),
        .prelu_shift_o(prelu_shift_o),
        .residual_multiplier_o(residual_multiplier_o),
        .residual_shift_o(residual_shift_o),
        .residual_zero_point_o(residual_zero_point_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    // Simple one-cycle-latency parameter memory model.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            param_rd_valid_i <= 1'b0;
            param_bias_i <= '0;
            param_requant_multiplier_i <= '0;
            param_requant_shift_i <= '0;
            param_prelu_multiplier_i <= '0;
            param_prelu_shift_i <= '0;
            param_residual_multiplier_i <= '0;
            param_residual_shift_i <= '0;
            param_residual_zero_point_i <= '0;
        end else begin
            param_rd_valid_i <= param_rd_en_o;
            param_bias_i <= 64'sd3000 + param_rd_addr_o;
            param_requant_multiplier_i <= 32'sd1000 + param_rd_addr_o;
            param_requant_shift_i <= param_rd_addr_o[5:0];
            param_prelu_multiplier_i <= 32'sd2000 + param_rd_addr_o;
            param_prelu_shift_i <= param_rd_addr_o[5:0] + 6'd1;
            param_residual_multiplier_i <= 32'sd4000 + param_rd_addr_o;
            param_residual_shift_i <= param_rd_addr_o[5:0] + 6'd2;
            param_residual_zero_point_i <= 64'sd5000 + param_rd_addr_o;
        end
    end

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        start_i = 1'b0;
        post_mode_i = 3'd2;
        output_zero_point_i = -8'sd3;
        param_base_i = 8'd20;
        current_num_filter_i = 4'd4;
        psum_i = '0;
        valid_i = 1'b0;
        residual_i = '0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;

        psum_i = 32'sd10;
        residual_i = 32'sd100;
        valid_i = 1'b1;
        #1 check(param_rd_en_o && param_rd_addr_o == 8'd20, "ch0 address mismatch");

        @(posedge clk);
        #1 begin
            check(valid_o && psum_o == 32'sd10, "first psum alignment mismatch");
            check(bias_o == 64'sd3020, "first bias mismatch");
            check(requant_multiplier_o == 32'sd1020, "first requant multiplier mismatch");
            check(prelu_multiplier_o == 32'sd2020, "first prelu multiplier mismatch");
            check(residual_multiplier_o == 32'sd4020, "first residual multiplier mismatch");
            check(residual_zero_point_o == 64'sd5020, "first residual zero-point mismatch");
        end

        @(negedge clk);
        psum_i = 32'sd11;
        residual_i = 32'sd101;
        #1 check(param_rd_en_o && param_rd_addr_o == 8'd21, "ch1 address mismatch");

        @(posedge clk);
        #1 begin
            check(valid_o && psum_o == 32'sd11, "second psum alignment mismatch");
            check(requant_multiplier_o == 32'sd1021, "second requant multiplier mismatch");
        end

        @(negedge clk);
        psum_i = 32'sd12;
        residual_i = 32'sd102;
        #1 check(param_rd_en_o && param_rd_addr_o == 8'd22, "ch2 address mismatch");

        @(negedge clk);
        psum_i = 32'sd13;
        residual_i = 32'sd103;
        #1 check(param_rd_en_o && param_rd_addr_o == 8'd23, "ch3 address mismatch");

        @(negedge clk);
        psum_i = 32'sd14;
        residual_i = 32'sd104;
        #1 check(param_rd_en_o && param_rd_addr_o == 8'd20, "wrapped ch0 address mismatch");

        @(negedge clk);
        valid_i = 1'b0;
        repeat (3) @(posedge clk);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_param_scheduler FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_param_scheduler PASSED");
        $finish;
    end
endmodule
