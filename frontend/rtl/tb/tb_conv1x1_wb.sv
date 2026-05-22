`timescale 1ns/1ps

module tb_conv1x1_wb;
    parameter int ROW = 4;
    parameter int COL = 4;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int BIAS_SHIFT = 16;
    parameter int OUT_W = 8;
    parameter int MULT_W = 32;
    parameter int SHIFT_W = 6;
    parameter int DIM_W = 16;
    parameter int GB_DATA_W = COL * OUT_W;
    parameter int GB_ADDR_W = 16;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic valid_tile_i;
    logic valid_tile_o;
    logic [DIM_W-1:0] row_base_i;
    logic [DIM_W-1:0] col_base_i;
    logic [DIM_W-1:0] m_size_i;
    logic [DIM_W-1:0] n_size_i;
    logic [1:0] mode_i;
    logic valid_i [ROW][COL];
    logic signed [ACC_W-1:0] acc_i [ROW][COL];
    logic signed [ACC_W-1:0] residual_i [ROW][COL];
    logic signed [BIAS_W-1:0] bias_i [COL];
    logic signed [MULT_W-1:0] multiplier_i [COL];
    logic [SHIFT_W-1:0] shift_i [COL];
    logic signed [OUT_W-1:0] zero_point_i [COL];
    logic signed [MULT_W-1:0] prelu_multiplier_i [COL];
    logic [SHIFT_W-1:0] prelu_shift_i [COL];
    logic signed [MULT_W-1:0] residual_multiplier_i [COL];
    logic [SHIFT_W-1:0] residual_shift_i [COL];
    logic signed [ACC_W-1:0] residual_zero_point_i [COL];
    logic wb_capture_en_i;
    logic wb_done_o;
    logic [DIM_W-1:0] wb_m_size_i;
    logic [DIM_W-1:0] wb_n_size_i;
    logic [GB_ADDR_W-1:0] wb_out_base_addr_i;
    logic gb_ao_wr_valid_o;
    logic [GB_ADDR_W-1:0] gb_ao_wr_addr_o;
    logic [GB_DATA_W-1:0] gb_ao_wr_data_o;
    logic [COL-1:0] gb_ao_wr_mask_o;

    logic [GB_DATA_W-1:0] got_data [ROW];
    logic [GB_ADDR_W-1:0] got_addr [ROW];
    int write_count;
    int pass_cnt;
    int fail_cnt;

    localparam logic [1:0] MODE_REQUANT  = 2'd0;
    localparam logic [1:0] MODE_PRELU    = 2'd1;
    localparam logic [1:0] MODE_RESIDUAL = 2'd2;

    conv1x1_wb #(
        .ROW(ROW),
        .COL(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W),
        .GB_DATA_W(GB_DATA_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_tile_i(valid_tile_i),
        .valid_tile_o(valid_tile_o),
        .row_base_i(row_base_i),
        .col_base_i(col_base_i),
        .m_size_i(m_size_i),
        .n_size_i(n_size_i),
        .mode_i(mode_i),
        .valid_i(valid_i),
        .acc_i(acc_i),
        .residual_i(residual_i),
        .bias_i(bias_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .zero_point_i(zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .wb_capture_en_i(wb_capture_en_i),
        .wb_done_o(wb_done_o),
        .wb_m_size_i(wb_m_size_i),
        .wb_n_size_i(wb_n_size_i),
        .wb_out_base_addr_i(wb_out_base_addr_i),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o)
    );

    function automatic logic signed [OUT_W-1:0] clamp_ref(input longint signed value);
        begin
            if (value > 127) begin
                clamp_ref = 127;
            end else if (value < -128) begin
                clamp_ref = -128;
            end else begin
                clamp_ref = value[OUT_W-1:0];
            end
        end
    endfunction

    function automatic longint signed round_shift_ref(input longint signed value, input int shift);
        longint signed rounded;
        begin
            if (shift == 0) begin
                rounded = value;
            end else begin
                rounded = value + (64'sd1 <<< (shift - 1));
            end
            round_shift_ref = rounded >>> shift;
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] postprocess_ref(
        input int signed acc,
        input longint signed bias,
        input int signed residual,
        input logic [1:0] mode,
        input int signed multiplier,
        input int shift,
        input int signed zero_point,
        input int signed prelu_multiplier,
        input int prelu_shift,
        input int signed residual_multiplier,
        input int residual_shift,
        input int signed residual_zero_point
    );
        longint signed value;
        longint signed product;
        begin
            value = (longint'(acc) <<< BIAS_SHIFT) + bias;
            if (mode == MODE_RESIDUAL) begin
                product = (longint'(residual) + longint'(residual_zero_point)) *
                          longint'(residual_multiplier);
                value = value + (round_shift_ref(product, residual_shift) <<< BIAS_SHIFT);
            end else if ((mode == MODE_PRELU) && (value < 0)) begin
                product = value * longint'(prelu_multiplier);
                value = round_shift_ref(product, prelu_shift);
            end
            product = value * longint'(multiplier);
            value = round_shift_ref(product, shift + BIAS_SHIFT) + zero_point;
            postprocess_ref = clamp_ref(value);
        end
    endfunction

    function automatic logic [GB_DATA_W-1:0] expected_row(input int r);
        logic [GB_DATA_W-1:0] packed_word;
        logic signed [OUT_W-1:0] lane;
        begin
            packed_word = '0;
            for (int c = 0; c < COL; c++) begin
                lane = postprocess_ref(acc_i[r][c], bias_i[c], residual_i[r][c],
                                       mode_i, multiplier_i[c], shift_i[c],
                                       zero_point_i[c], prelu_multiplier_i[c],
                                       prelu_shift_i[c], residual_multiplier_i[c],
                                       residual_shift_i[c], residual_zero_point_i[c]);
                packed_word[c*OUT_W +: OUT_W] = lane;
            end
            expected_row = packed_word;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        begin
            if (!cond) begin
                fail_cnt++;
                $error("%s", msg);
            end else begin
                pass_cnt++;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (rst_n && gb_ao_wr_valid_o) begin
            got_addr[write_count] <= gb_ao_wr_addr_o;
            got_data[write_count] <= gb_ao_wr_data_o;
            write_count <= write_count + 1;
        end
    end

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        write_count = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        valid_tile_i = 1'b0;
        wb_capture_en_i = 1'b0;
        row_base_i = 2;
        col_base_i = 4;
        m_size_i = 6;
        n_size_i = 8;
        wb_m_size_i = m_size_i;
        wb_n_size_i = n_size_i;
        wb_out_base_addr_i = 16'd100;
        mode_i = MODE_PRELU;

        for (int c = 0; c < COL; c++) begin
            bias_i[c] = ((c - 1) * 7) <<< BIAS_SHIFT;
            multiplier_i[c] = c + 1;
            shift_i[c] = c;
            zero_point_i[c] = c - 1;
            prelu_multiplier_i[c] = 1;
            prelu_shift_i[c] = 2;
            residual_multiplier_i[c] = 1;
            residual_shift_i[c] = 0;
            residual_zero_point_i[c] = 0;
        end

        for (int r = 0; r < ROW; r++) begin
            for (int c = 0; c < COL; c++) begin
                valid_i[r][c] = 1'b1;
                acc_i[r][c] = (r * 31) - (c * 19) - 20;
                residual_i[r][c] = (r * 5) - (c * 3);
            end
            got_addr[r] = '0;
            got_data[r] = '0;
        end

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        valid_tile_i = 1'b1;
        @(negedge clk);
        valid_tile_i = 1'b0;

        wait (valid_tile_o === 1'b1);
        @(posedge clk);
        #1;
        check(write_count == ROW, $sformatf("expected %0d writes before valid_tile_o, got %0d", ROW, write_count));

        @(negedge clk);
        wb_capture_en_i = 1'b1;
        @(posedge clk);
        #1;
        check(wb_done_o === 1'b1, "wb_done_o missing after wb_capture_en_i");
        @(negedge clk);
        wb_capture_en_i = 1'b0;

        for (int r = 0; r < ROW; r++) begin
            check(got_addr[r] == (GB_ADDR_W'(wb_out_base_addr_i) +
                                  ((GB_ADDR_W'(row_base_i) + GB_ADDR_W'(r)) *
                                   ((GB_ADDR_W'(n_size_i) + GB_ADDR_W'(COL - 1)) / GB_ADDR_W'(COL))) +
                                  (GB_ADDR_W'(col_base_i) / GB_ADDR_W'(COL))),
                  $sformatf("addr mismatch row=%0d got=%0d", r, got_addr[r]));
            check(got_data[r] == expected_row(r),
                  $sformatf("data mismatch row=%0d exp=0x%0h got=0x%0h",
                            r, expected_row(r), got_data[r]));
        end

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] conv1x1_wb FAILED pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("[TB] conv1x1_wb PASSED pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $finish;
    end
endmodule
