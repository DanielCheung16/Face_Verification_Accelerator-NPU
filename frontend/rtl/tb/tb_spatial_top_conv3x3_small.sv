`timescale 1ns/1ps

module tb_spatial_top_conv3x3_small;
    parameter int GB_ADDR_W = 20;
    parameter int GB_DATA_W = 128;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int ACT_DEPTH = 1;
    parameter int WGT_DEPTH = 4;
    parameter int ELEM_CNT_W = 32;
    parameter int PARAM_ADDR_W = 16;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = GB_DATA_W / DATA_W;
    localparam int IFMAP_SIZE = 7;
    localparam int IC = 3;
    localparam int OC = 64;
    localparam int OC_WORDS = OC / LANES;
    localparam int OUTPUTS = IFMAP_SIZE * IFMAP_SIZE * OC;
    localparam int OUTPUT_WORDS = OUTPUTS / LANES;
    localparam int MEM_DEPTH = 4096;
    localparam int PARAM_DEPTH = 64;
    localparam int OUT_BASE = 1024;
    localparam int FILTER_CNT_W = $clog2(WGT_DEPTH * LANES) + 1;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic start_i;
    logic [GB_ADDR_W-1:0] gb_act_rd_addr_o;
    logic [GB_DATA_W-1:0] gb_act_rd_data_i;
    logic gb_act_rd_en_o;
    logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o;
    logic [GB_DATA_W-1:0] gb_wgt_rd_data_i;
    logic gb_wgt_rd_en_o;
    logic gb_ao_wr_valid_o;
    logic [GB_ADDR_W-1:0] gb_ao_wr_addr_o;
    logic [GB_DATA_W-1:0] gb_ao_wr_data_o;
    logic [LANES-1:0] gb_ao_wr_mask_o;
    logic busy_o;
    logic done_o;

    logic quant_common_rd_en_o;
    logic [PARAM_ADDR_W-1:0] quant_common_rd_addr_o;
    logic quant_common_rd_valid_i;
    logic quant_prelu_rd_en_o;
    logic [PARAM_ADDR_W-1:0] quant_prelu_rd_addr_o;
    logic quant_prelu_rd_valid_i;
    logic quant_residual_rd_en_o;
    logic [PARAM_ADDR_W-1:0] quant_residual_rd_addr_o;
    logic quant_residual_rd_valid_i;
    logic signed [63:0] quant_param_bias_i;
    logic signed [31:0] quant_param_requant_multiplier_i;
    logic [5:0] quant_param_requant_shift_i;
    logic signed [31:0] quant_param_prelu_multiplier_i;
    logic [5:0] quant_param_prelu_shift_i;
    logic signed [31:0] quant_param_residual_multiplier_i;
    logic [5:0] quant_param_residual_shift_i;
    logic signed [63:0] quant_param_residual_zero_point_i;

    logic [GB_DATA_W-1:0] ao_mem [MEM_DEPTH];
    logic [GB_DATA_W-1:0] wgt_mem [MEM_DEPTH];
    logic [GB_DATA_W-1:0] exp_mem [MEM_DEPTH];
    int fail_cnt;
    int write_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_top #(
        .GB_ADDR_W(GB_ADDR_W),
        .GB_DATA_W(GB_DATA_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .ACT_DEPTH(ACT_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .ELEM_CNT_W(ELEM_CNT_W),
        .PARAM_ADDR_W(PARAM_ADDR_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .act_base_addr_i('0),
        .wgt_base_addr_i('0),
        .out_base_addr_i(GB_ADDR_W'(OUT_BASE)),
        .output_elements_i(ELEM_CNT_W'(OUTPUTS)),
        .bias_base_i('0),
        .requant_mult_base_i('0),
        .requant_shift_base_i('0),
        .prelu_mult_base_i('0),
        .prelu_shift_base_i('0),
        .residual_mult_base_i('0),
        .residual_shift_base_i('0),
        .residual_zero_point_base_i('0),
        .num_filter_code_i(2'd0),
        .ifmap_size_code_i(3'd0),
        .stride_i(1'b0),
        .pad_i(1'b1),
        .pad_value_i(8'sd0),
        .conv_mode_i(1'b1),
        .input_channel_count_i(FILTER_CNT_W'(IC)),
        .input_channel_words_shift_i(4'd0),
        .current_num_filter_i(FILTER_CNT_W'(OC)),
        .post_mode_i(3'd0),
        .residual_en_i(1'b0),
        .residual_i('0),
        .output_zero_point_i('0),
        .quant_common_rd_en_o(quant_common_rd_en_o),
        .quant_common_rd_addr_o(quant_common_rd_addr_o),
        .quant_common_rd_valid_i(quant_common_rd_valid_i),
        .quant_prelu_rd_en_o(quant_prelu_rd_en_o),
        .quant_prelu_rd_addr_o(quant_prelu_rd_addr_o),
        .quant_prelu_rd_valid_i(quant_prelu_rd_valid_i),
        .quant_residual_rd_en_o(quant_residual_rd_en_o),
        .quant_residual_rd_addr_o(quant_residual_rd_addr_o),
        .quant_residual_rd_valid_i(quant_residual_rd_valid_i),
        .quant_param_bias_i(quant_param_bias_i),
        .quant_param_requant_multiplier_i(quant_param_requant_multiplier_i),
        .quant_param_requant_shift_i(quant_param_requant_shift_i),
        .quant_param_prelu_multiplier_i(quant_param_prelu_multiplier_i),
        .quant_param_prelu_shift_i(quant_param_prelu_shift_i),
        .quant_param_residual_multiplier_i(quant_param_residual_multiplier_i),
        .quant_param_residual_shift_i(quant_param_residual_shift_i),
        .quant_param_residual_zero_point_i(quant_param_residual_zero_point_i),
        .gb_act_rd_en_o(gb_act_rd_en_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_en_o(gb_wgt_rd_en_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o),
        .busy_o(busy_o),
        .done_o(done_o)
    );

    quant_param_mem #(
        .COMMON_PARAM_DEPTH(PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(PARAM_DEPTH),
        .COMMON_PARAM_ADDR_W(PARAM_ADDR_W),
        .PRELU_PARAM_ADDR_W(PARAM_ADDR_W),
        .RESIDUAL_PARAM_ADDR_W(PARAM_ADDR_W)
    ) u_quant_param_mem (
        .clk(clk),
        .rst_n(rst_n),
        .common_rd_en_i(quant_common_rd_en_o),
        .common_rd_addr_i(quant_common_rd_addr_o),
        .prelu_rd_en_i(quant_prelu_rd_en_o),
        .prelu_rd_addr_i(quant_prelu_rd_addr_o),
        .residual_rd_en_i(quant_residual_rd_en_o),
        .residual_rd_addr_i(quant_residual_rd_addr_o),
        .common_rd_valid_o(quant_common_rd_valid_i),
        .prelu_rd_valid_o(quant_prelu_rd_valid_i),
        .residual_rd_valid_o(quant_residual_rd_valid_i),
        .bias_o(quant_param_bias_i),
        .requant_multiplier_o(quant_param_requant_multiplier_i),
        .requant_shift_o(quant_param_requant_shift_i),
        .prelu_multiplier_o(quant_param_prelu_multiplier_i),
        .prelu_shift_o(quant_param_prelu_shift_i),
        .residual_multiplier_o(quant_param_residual_multiplier_i),
        .residual_shift_o(quant_param_residual_shift_i),
        .residual_zero_point_o(quant_param_residual_zero_point_i)
    );

    function automatic int signed act_value(input int x, input int y, input int ic);
        begin
            act_value = ((x + y + ic) % 3) - 1;
        end
    endfunction

    function automatic int signed wgt_value(input int ic, input int pos, input int oc);
        begin
            wgt_value = ((ic + pos + oc) % 3) - 1;
        end
    endfunction

    function automatic int signed sat8(input int signed value);
        begin
            if (value > 127) sat8 = 127;
            else if (value < -128) sat8 = -128;
            else sat8 = value;
        end
    endfunction

    function automatic int signed golden_psum(input int ox, input int oy, input int oc);
        int signed acc;
        int ix;
        int iy;
        int pos;
        begin
            acc = 0;
            for (int ic = 0; ic < IC; ic++) begin
                pos = 0;
                for (int kx = 0; kx < 3; kx++) begin
                    for (int ky = 0; ky < 3; ky++) begin
                        ix = ox + kx - 1;
                        iy = oy + ky - 1;
                        if ((ix >= 0) && (ix < IFMAP_SIZE) &&
                            (iy >= 0) && (iy < IFMAP_SIZE)) begin
                            acc += act_value(ix, iy, ic) * wgt_value(ic, pos, oc);
                        end
                        pos++;
                    end
                end
            end
            golden_psum = acc;
        end
    endfunction

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic set_word_lane(
        inout logic [GB_DATA_W-1:0] word,
        input int lane,
        input int signed value
    );
        begin
            word[lane*DATA_W +: DATA_W] = DATA_W'(value);
        end
    endtask

    initial begin
        fail_cnt = 0;
        write_cnt = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        start_i = 1'b0;

        for (int addr = 0; addr < MEM_DEPTH; addr++) begin
            ao_mem[addr] = '0;
            wgt_mem[addr] = '0;
            exp_mem[addr] = '0;
        end

        for (int x = 0; x < IFMAP_SIZE; x++) begin
            for (int y = 0; y < IFMAP_SIZE; y++) begin
                int addr;
                addr = x * IFMAP_SIZE + y;
                for (int ic = 0; ic < IC; ic++) begin
                    set_word_lane(ao_mem[addr], ic, act_value(x, y, ic));
                end
            end
        end

        for (int ic = 0; ic < IC; ic++) begin
            for (int pos = 0; pos < 9; pos++) begin
                for (int tile = 0; tile < OC_WORDS; tile++) begin
                    int addr;
                    addr = (ic * 9 + pos) * OC_WORDS + tile;
                    for (int lane = 0; lane < LANES; lane++) begin
                        set_word_lane(wgt_mem[addr], lane,
                                      wgt_value(ic, pos, tile * LANES + lane));
                    end
                end
            end
        end

        for (int x = 0; x < IFMAP_SIZE; x++) begin
            for (int y = 0; y < IFMAP_SIZE; y++) begin
                for (int tile = 0; tile < OC_WORDS; tile++) begin
                    int addr;
                    addr = OUT_BASE + (x * IFMAP_SIZE + y) * OC_WORDS + tile;
                    for (int lane = 0; lane < LANES; lane++) begin
                        set_word_lane(exp_mem[addr], lane,
                                      sat8(golden_psum(x, y, tile * LANES + lane)));
                    end
                end
            end
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;

        wait (done_o);
        repeat (2) @(posedge clk);

        check(write_cnt == OUTPUT_WORDS,
              $sformatf("write words expected=%0d got=%0d", OUTPUT_WORDS, write_cnt));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_top conv3x3 small FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_top conv3x3 small PASSED words=%0d", write_cnt);
        $finish;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            gb_act_rd_data_i <= '0;
            gb_wgt_rd_data_i <= '0;
        end else begin
            if (gb_act_rd_en_o) begin
                gb_act_rd_data_i <= ao_mem[gb_act_rd_addr_o];
            end
            if (gb_wgt_rd_en_o) begin
                gb_wgt_rd_data_i <= wgt_mem[gb_wgt_rd_addr_o];
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && gb_ao_wr_valid_o) begin
            check(gb_ao_wr_addr_o == GB_ADDR_W'(OUT_BASE + write_cnt),
                  $sformatf("addr mismatch word=%0d expected=0x%0h got=0x%0h",
                            write_cnt, OUT_BASE + write_cnt, gb_ao_wr_addr_o));
            check(gb_ao_wr_mask_o == {LANES{1'b1}},
                  $sformatf("mask mismatch word=%0d got=0x%0h", write_cnt, gb_ao_wr_mask_o));
            check(gb_ao_wr_data_o == exp_mem[gb_ao_wr_addr_o],
                  $sformatf("data mismatch word=%0d addr=0x%0h expected=%0h got=%0h",
                            write_cnt, gb_ao_wr_addr_o, exp_mem[gb_ao_wr_addr_o], gb_ao_wr_data_o));
            write_cnt++;
        end
    end

    initial begin
        repeat (120000) @(posedge clk);
        $fatal(1, "[TB] timeout write_cnt=%0d expected=%0d", write_cnt, OUTPUT_WORDS);
    end
endmodule
