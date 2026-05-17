`timescale 1ns/1ps

module tb_spatial_wb;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int DATA_W = 8;
    parameter int GB_DATA_W = 128;
    parameter int GB_ADDR_W = 16;
    parameter int ELEM_CNT_W = 16;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = GB_DATA_W / DATA_W;
    localparam int MASK_W = LANES;
    localparam int NUM_ELEMS = 20;
    localparam int OUT_BASE = 16'h120;

    logic clk;
    logic rst_n;
    logic start_i;
    logic [GB_ADDR_W-1:0] out_base_addr_i;
    logic [ELEM_CNT_W-1:0] output_elements_i;
    logic signed [ACC_W-1:0] psum_i;
    logic valid_i;
    logic [2:0] post_mode_i;
    logic residual_en_i;
    logic signed [ACC_W-1:0] residual_i;
    logic signed [BIAS_W-1:0] bias_i;
    logic signed [31:0] residual_multiplier_i;
    logic [5:0] residual_shift_i;
    logic signed [BIAS_W-1:0] residual_zero_point_i;
    logic signed [31:0] requant_multiplier_i;
    logic [5:0] requant_shift_i;
    logic signed [ACC_W-1:0] output_zero_point_i;
    logic signed [31:0] prelu_multiplier_i;
    logic [5:0] prelu_shift_i;
    logic gb_ao_wr_valid_o;
    logic [GB_ADDR_W-1:0] gb_ao_wr_addr_o;
    logic [GB_DATA_W-1:0] gb_ao_wr_data_o;
    logic [MASK_W-1:0] gb_ao_wr_mask_o;
    logic busy_o;
    logic done_o;

    int fail_cnt;
    int write_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_wb #(
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W),
        .ELEM_CNT_W(ELEM_CNT_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .out_base_addr_i(out_base_addr_i),
        .output_elements_i(output_elements_i),
        .psum_i(psum_i),
        .valid_i(valid_i),
        .post_mode_i(post_mode_i),
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
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o),
        .busy_o(busy_o),
        .done_o(done_o)
    );

    function automatic logic [7:0] sat8(input int signed value);
        begin
            if (value > 127) begin
                sat8 = 8'h7f;
            end else if (value < -128) begin
                sat8 = 8'h80;
            end else begin
                sat8 = value[7:0];
            end
        end
    endfunction

    function automatic int signed psum_value(input int idx);
        begin
            case (idx)
                0: psum_value = -200;
                1: psum_value = -128;
                2: psum_value = -1;
                17: psum_value = 150;
                default: psum_value = idx * 3 - 20;
            endcase
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic check_word(input int word_idx);
        int base_idx;
        int valid_lanes;
        logic [GB_DATA_W-1:0] exp_data;
        logic [MASK_W-1:0] exp_mask;
        begin
            exp_data = '0;
            exp_mask = '0;
            base_idx = word_idx * LANES;
            valid_lanes = (NUM_ELEMS - base_idx) >= LANES ? LANES : (NUM_ELEMS - base_idx);
            for (int lane = 0; lane < valid_lanes; lane++) begin
                exp_data[lane*DATA_W +: DATA_W] = sat8(psum_value(base_idx + lane));
                exp_mask[lane] = 1'b1;
            end

            check(gb_ao_wr_addr_o == GB_ADDR_W'(OUT_BASE + word_idx * LANES),
                  $sformatf("word %0d addr expected=0x%0h got=0x%0h",
                            word_idx, OUT_BASE + word_idx * LANES, gb_ao_wr_addr_o));
            check(gb_ao_wr_data_o == exp_data,
                  $sformatf("word %0d data mismatch", word_idx));
            check(gb_ao_wr_mask_o == exp_mask,
                  $sformatf("word %0d mask expected=0x%0h got=0x%0h",
                            word_idx, exp_mask, gb_ao_wr_mask_o));
        end
    endtask

    initial begin
        fail_cnt = 0;
        write_cnt = 0;
        rst_n = 1'b0;
        start_i = 1'b0;
        out_base_addr_i = GB_ADDR_W'(OUT_BASE);
        output_elements_i = ELEM_CNT_W'(NUM_ELEMS);
        psum_i = '0;
        valid_i = 1'b0;
        post_mode_i = 3'd0; // bypass saturate
        residual_en_i = 1'b0;
        residual_i = '0;
        bias_i = '0;
        residual_multiplier_i = 32'sd1;
        residual_shift_i = 6'd0;
        residual_zero_point_i = '0;
        requant_multiplier_i = 32'sd1;
        requant_shift_i = 6'd0;
        output_zero_point_i = '0;
        prelu_multiplier_i = 32'sd1;
        prelu_shift_i = 6'd0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;

        for (int idx = 0; idx < NUM_ELEMS; idx++) begin
            @(negedge clk);
            psum_i = ACC_W'(psum_value(idx));
            valid_i = 1'b1;
        end
        @(negedge clk);
        valid_i = 1'b0;
        psum_i = '0;

        wait (done_o);
        repeat (2) @(posedge clk);

        check(write_cnt == 2, $sformatf("write count expected=2 got=%0d", write_cnt));
        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_wb FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_wb PASSED writes=%0d", write_cnt);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && gb_ao_wr_valid_o) begin
            check_word(write_cnt);
            write_cnt++;
        end
    end
endmodule
