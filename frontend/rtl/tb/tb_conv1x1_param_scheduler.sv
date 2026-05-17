import layer_defs_pkg::*;

module tb_conv1x1_param_scheduler;
    localparam int COL = 4;
    localparam int BIAS_W = 64;
    localparam int OUT_W = 8;
    localparam int MULT_W = 32;
    localparam int SHIFT_W = 6;
    localparam int PARAM_ADDR_W = 8;
    localparam int DIM_W = 16;
    localparam int ACC_W = 32;

    logic clk;
    logic rst_n;
    logic start;
    logic busy;
    logic params_valid;

    logic [DIM_W-1:0] col_base;
    postprocess_mode_t post_mode;
    logic signed [OUT_W-1:0] output_zero_point;
    logic [PARAM_ADDR_W-1:0] common_param_base;
    logic [PARAM_ADDR_W-1:0] prelu_param_base;
    logic [PARAM_ADDR_W-1:0] residual_param_base;

    logic common_rd_en;
    logic [PARAM_ADDR_W-1:0] common_rd_addr;
    logic common_rd_valid;
    logic prelu_rd_en;
    logic [PARAM_ADDR_W-1:0] prelu_rd_addr;
    logic prelu_rd_valid;
    logic residual_rd_en;
    logic [PARAM_ADDR_W-1:0] residual_rd_addr;
    logic residual_rd_valid;

    logic signed [BIAS_W-1:0] param_bias;
    logic signed [MULT_W-1:0] param_requant_multiplier;
    logic [SHIFT_W-1:0] param_requant_shift;
    logic signed [MULT_W-1:0] param_prelu_multiplier;
    logic [SHIFT_W-1:0] param_prelu_shift;
    logic signed [MULT_W-1:0] param_residual_multiplier;
    logic [SHIFT_W-1:0] param_residual_shift;
    logic signed [BIAS_W-1:0] param_residual_zero_point;

    logic signed [BIAS_W-1:0] bias [COL];
    logic signed [MULT_W-1:0] multiplier [COL];
    logic [SHIFT_W-1:0] shift [COL];
    logic signed [OUT_W-1:0] zero_point [COL];
    logic signed [MULT_W-1:0] prelu_multiplier [COL];
    logic [SHIFT_W-1:0] prelu_shift [COL];
    logic signed [MULT_W-1:0] residual_multiplier [COL];
    logic [SHIFT_W-1:0] residual_shift [COL];
    logic signed [ACC_W-1:0] residual_zero_point [COL];

    int common_read_cnt;
    int prelu_read_cnt;
    int residual_read_cnt;
    int fail_cnt;

    conv1x1_param_scheduler #(
        .COL(COL),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .DIM_W(DIM_W),
        .ACC_W(ACC_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start),
        .busy_o(busy),
        .params_valid_o(params_valid),
        .col_base_i(col_base),
        .post_mode_i(post_mode),
        .output_zero_point_i(output_zero_point),
        .common_param_base_i(common_param_base),
        .prelu_param_base_i(prelu_param_base),
        .residual_param_base_i(residual_param_base),
        .common_rd_en_o(common_rd_en),
        .common_rd_addr_o(common_rd_addr),
        .common_rd_valid_i(common_rd_valid),
        .prelu_rd_en_o(prelu_rd_en),
        .prelu_rd_addr_o(prelu_rd_addr),
        .prelu_rd_valid_i(prelu_rd_valid),
        .residual_rd_en_o(residual_rd_en),
        .residual_rd_addr_o(residual_rd_addr),
        .residual_rd_valid_i(residual_rd_valid),
        .param_bias_i(param_bias),
        .param_requant_multiplier_i(param_requant_multiplier),
        .param_requant_shift_i(param_requant_shift),
        .param_prelu_multiplier_i(param_prelu_multiplier),
        .param_prelu_shift_i(param_prelu_shift),
        .param_residual_multiplier_i(param_residual_multiplier),
        .param_residual_shift_i(param_residual_shift),
        .param_residual_zero_point_i(param_residual_zero_point),
        .bias_o(bias),
        .multiplier_o(multiplier),
        .shift_o(shift),
        .zero_point_o(zero_point),
        .prelu_multiplier_o(prelu_multiplier),
        .prelu_shift_o(prelu_shift),
        .residual_multiplier_o(residual_multiplier),
        .residual_shift_o(residual_shift),
        .residual_zero_point_o(residual_zero_point)
    );

    always #5 clk = ~clk;

    // One-cycle latency fake ROM banks. The returned values are simple
    // functions of the delayed address so expected data is easy to check.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            common_rd_valid <= 1'b0;
            prelu_rd_valid <= 1'b0;
            residual_rd_valid <= 1'b0;
            param_bias <= '0;
            param_requant_multiplier <= '0;
            param_requant_shift <= '0;
            param_prelu_multiplier <= '0;
            param_prelu_shift <= '0;
            param_residual_multiplier <= '0;
            param_residual_shift <= '0;
            param_residual_zero_point <= '0;
        end else begin
            common_rd_valid <= common_rd_en;
            prelu_rd_valid <= prelu_rd_en;
            residual_rd_valid <= residual_rd_en;

            if (common_rd_en) begin
                param_bias <= BIAS_W'(1000 + common_rd_addr);
                param_requant_multiplier <= MULT_W'(2000 + common_rd_addr);
                param_requant_shift <= common_rd_addr[SHIFT_W-1:0];
            end
            if (prelu_rd_en) begin
                param_prelu_multiplier <= MULT_W'(3000 + prelu_rd_addr);
                param_prelu_shift <= prelu_rd_addr[SHIFT_W-1:0];
            end
            if (residual_rd_en) begin
                param_residual_multiplier <= MULT_W'(4000 + residual_rd_addr);
                param_residual_shift <= residual_rd_addr[SHIFT_W-1:0];
                param_residual_zero_point <= BIAS_W'(5000 + residual_rd_addr);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            common_read_cnt <= 0;
            prelu_read_cnt <= 0;
            residual_read_cnt <= 0;
        end else begin
            if (start) begin
                common_read_cnt <= 0;
                prelu_read_cnt <= 0;
                residual_read_cnt <= 0;
            end else begin
                if (common_rd_en) begin
                    common_read_cnt <= common_read_cnt + 1;
                end
                if (prelu_rd_en) begin
                    prelu_read_cnt <= prelu_read_cnt + 1;
                end
                if (residual_rd_en) begin
                    residual_read_cnt <= residual_read_cnt + 1;
                end
            end
        end
    end

    task automatic expect_eq(input int got, input int exp, input string name);
        if (got !== exp) begin
            $display("[TB][FAIL] %s got=%0d exp=%0d", name, got, exp);
            fail_cnt++;
        end
    endtask

    task automatic run_case(
        input postprocess_mode_t mode,
        input int common_base,
        input int prelu_base,
        input int residual_base,
        input int col,
        input int zp
    );
        int common_addr;
        int prelu_addr;
        int residual_addr;
        begin
            @(negedge clk);
            post_mode = mode;
            common_param_base = PARAM_ADDR_W'(common_base);
            prelu_param_base = PARAM_ADDR_W'(prelu_base);
            residual_param_base = PARAM_ADDR_W'(residual_base);
            col_base = DIM_W'(col);
            output_zero_point = OUT_W'(zp);
            start = 1'b1;

            @(negedge clk);
            start = 1'b0;

            wait (params_valid === 1'b1);
            @(negedge clk);

            expect_eq(common_read_cnt, COL, "common_read_cnt");
            if (mode == MODE_PRELU) begin
                expect_eq(prelu_read_cnt, COL, "prelu_read_cnt");
            end else begin
                expect_eq(prelu_read_cnt, 0, "prelu_read_cnt");
            end
            if (mode == MODE_RESIDUAL) begin
                expect_eq(residual_read_cnt, COL, "residual_read_cnt");
            end else begin
                expect_eq(residual_read_cnt, 0, "residual_read_cnt");
            end

            for (int c = 0; c < COL; c++) begin
                common_addr = common_base + col + c;
                prelu_addr = prelu_base + col + c;
                residual_addr = residual_base + col + c;

                expect_eq(bias[c], 1000 + common_addr, "bias");
                expect_eq(multiplier[c], 2000 + common_addr, "multiplier");
                expect_eq(shift[c], common_addr & ((1 << SHIFT_W) - 1), "shift");
                expect_eq(zero_point[c], zp, "zero_point");

                if (mode == MODE_PRELU) begin
                    expect_eq(prelu_multiplier[c], 3000 + prelu_addr, "prelu_multiplier");
                    expect_eq(prelu_shift[c], prelu_addr & ((1 << SHIFT_W) - 1), "prelu_shift");
                end else begin
                    expect_eq(prelu_multiplier[c], 1, "prelu_multiplier_default");
                    expect_eq(prelu_shift[c], 0, "prelu_shift_default");
                end

                if (mode == MODE_RESIDUAL) begin
                    expect_eq(residual_multiplier[c], 4000 + residual_addr, "residual_multiplier");
                    expect_eq(residual_shift[c], residual_addr & ((1 << SHIFT_W) - 1), "residual_shift");
                    expect_eq(residual_zero_point[c], 5000 + residual_addr, "residual_zero_point");
                end else begin
                    expect_eq(residual_multiplier[c], 1, "residual_multiplier_default");
                    expect_eq(residual_shift[c], 0, "residual_shift_default");
                    expect_eq(residual_zero_point[c], 0, "residual_zero_point_default");
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        post_mode = MODE_REQUANT;
        output_zero_point = '0;
        common_param_base = '0;
        prelu_param_base = '0;
        residual_param_base = '0;
        col_base = '0;
        fail_cnt = 0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        run_case(MODE_REQUANT, 10, 40, 70, 3, -7);
        run_case(MODE_PRELU, 20, 50, 80, 5, 4);
        run_case(MODE_RESIDUAL, 30, 60, 90, 1, -2);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] conv1x1_param_scheduler FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] conv1x1_param_scheduler PASSED");
        $finish;
    end

endmodule
