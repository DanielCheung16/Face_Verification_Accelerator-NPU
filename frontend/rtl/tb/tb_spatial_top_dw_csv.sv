`timescale 1ns/1ps

module tb_spatial_top_dw_csv;
    parameter int GB_ADDR_W = 20;
    parameter int GB_DATA_W = 128;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int ACT_DEPTH = 1;
    parameter int WGT_DEPTH = 8; // 128 channels / 16 lanes
    parameter int ELEM_CNT_W = 32;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = GB_DATA_W / DATA_W;
    localparam int MASK_W = LANES;
    localparam int C = 128;
    localparam int L1_IN_SIZE = 56;
    localparam int L1_OUT_SIZE = 28;
    localparam int L2_IN_SIZE = 28;
    localparam int L2_OUT_SIZE = 28;
    localparam int L1_OUTPUTS = L1_OUT_SIZE * L1_OUT_SIZE * C;
    localparam int L2_OUTPUTS = L2_OUT_SIZE * L2_OUT_SIZE * C;
    localparam int L1_WORDS = L1_OUTPUTS / LANES;
    localparam int L2_WORDS = L2_OUTPUTS / LANES;
    localparam int MEM_DEPTH = 700000;
    localparam int PARAM_DEPTH = 256;
    localparam int PARAM_ADDR_W = 16;
    localparam int ACT1_BASE = 0;
    localparam int ACT2_BASE = 420000;
    localparam int ACT3_BASE = 540000;
    localparam int WGT1_BASE = 0;
    localparam int WGT2_BASE = 4096;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic start_i;
    logic [GB_ADDR_W-1:0] act_base_addr_i;
    logic [GB_ADDR_W-1:0] wgt_base_addr_i;
    logic [GB_ADDR_W-1:0] out_base_addr_i;
    logic [ELEM_CNT_W-1:0] output_elements_i;
    logic [1:0] num_filter_code_i;
    logic [2:0] ifmap_size_code_i;
    logic stride_i;
    logic pad_i;
    logic [($clog2(WGT_DEPTH*LANES)+1)-1:0] current_num_filter_i;
    logic [2:0] post_mode_i;
    logic residual_en_i;
    logic signed [ACC_W-1:0] residual_i;
    logic signed [ACC_W-1:0] output_zero_point_i;
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

    logic gb_act_rd_en_o;
    logic [GB_ADDR_W-1:0] gb_act_rd_addr_o;
    logic [GB_DATA_W-1:0] gb_act_rd_data_i;
    logic gb_wgt_rd_en_o;
    logic [GB_ADDR_W-1:0] gb_wgt_rd_addr_o;
    logic [GB_DATA_W-1:0] gb_wgt_rd_data_i;
    logic gb_ao_wr_valid_o;
    logic [GB_ADDR_W-1:0] gb_ao_wr_addr_o;
    logic [GB_DATA_W-1:0] gb_ao_wr_data_o;
    logic [MASK_W-1:0] gb_ao_wr_mask_o;
    logic busy_o;
    logic done_o;

    logic [GB_DATA_W-1:0] ao_mem [MEM_DEPTH];
    logic [GB_DATA_W-1:0] wgt_mem [MEM_DEPTH];
    int signed layer1_act [L1_OUT_SIZE][L1_OUT_SIZE][C];
    int fail_cnt;
    int phase;
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
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .out_base_addr_i(out_base_addr_i),
        .output_elements_i(output_elements_i),
        .bias_base_i(16'd0),
        .requant_mult_base_i(16'd0),
        .requant_shift_base_i(16'd0),
        .prelu_mult_base_i(16'd0),
        .prelu_shift_base_i(16'd0),
        .residual_mult_base_i(16'd0),
        .residual_shift_base_i(16'd0),
        .residual_zero_point_base_i(16'd0),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .pad_i(pad_i),
        .pad_value_i(8'sd0),
        .conv_mode_i(1'b0),
        .input_channel_count_i(current_num_filter_i),
        .input_channel_words_shift_i(4'd0),
        .current_num_filter_i(current_num_filter_i),
        .post_mode_i(post_mode_i),
        .residual_en_i(residual_en_i),
        .residual_i(residual_i),
        .output_zero_point_i(output_zero_point_i),
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

    // Keep this top-level regression on the same per-channel parameter path as
    // the formal design, even though the current check uses bypass mode.
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

    function automatic int signed l1_act_value(input int x, input int y, input int ch);
        begin
            l1_act_value = ((x * 7 + y * 5 + ch * 3) % 31) - 15;
        end
    endfunction

    function automatic int signed l1_wgt_value(input int pos, input int ch);
        begin
            l1_wgt_value = ((pos * 4 + ch * 5 + 2) % 17) - 8;
        end
    endfunction

    function automatic int signed l2_wgt_value(input int pos, input int ch);
        begin
            l2_wgt_value = ((pos * 7 + ch * 3 + 1) % 19) - 9;
        end
    endfunction

    function automatic int signed sat8(input int signed value);
        begin
            if (value > 127) begin
                sat8 = 127;
            end else if (value < -128) begin
                sat8 = -128;
            end else begin
                sat8 = value;
            end
        end
    endfunction

    function automatic int signed golden_l1(input int ox, input int oy, input int ch);
        int signed acc;
        int ix;
        int iy;
        int pos;
        begin
            acc = 0;
            pos = 0;
            for (int kx = 0; kx < 3; kx++) begin
                for (int ky = 0; ky < 3; ky++) begin
                    ix = (ox << 1) + kx - 1;
                    iy = (oy << 1) + ky - 1;
                    if ((ix >= 0) && (ix < L1_IN_SIZE) &&
                        (iy >= 0) && (iy < L1_IN_SIZE)) begin
                        acc += l1_act_value(ix, iy, ch) * l1_wgt_value(pos, ch);
                    end
                    pos++;
                end
            end
            golden_l1 = acc;
        end
    endfunction

    function automatic int signed golden_l2(input int ox, input int oy, input int ch);
        int signed acc;
        int ix;
        int iy;
        int pos;
        begin
            acc = 0;
            pos = 0;
            for (int kx = 0; kx < 3; kx++) begin
                for (int ky = 0; ky < 3; ky++) begin
                    ix = ox + kx - 1;
                    iy = oy + ky - 1;
                    if ((ix >= 0) && (ix < L2_IN_SIZE) &&
                        (iy >= 0) && (iy < L2_IN_SIZE)) begin
                        acc += layer1_act[ix][iy][ch] * l2_wgt_value(pos, ch);
                    end
                    pos++;
                end
            end
            golden_l2 = acc;
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

    task automatic pulse_start;
        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
    endtask

    task automatic check_write_word(input int word_idx);
        int base_elem;
        int x;
        int y;
        int tile_group;
        int lane;
        int ch;
        int signed q_value;
        logic [GB_DATA_W-1:0] exp_data;
        begin
            exp_data = '0;
            base_elem = word_idx * LANES;
            tile_group = (base_elem / LANES) % (C / LANES);
            y = (base_elem / C) % L1_OUT_SIZE;
            x = base_elem / (C * L1_OUT_SIZE);

            for (lane = 0; lane < LANES; lane++) begin
                ch = tile_group * LANES + lane;
                if (phase == 1) begin
                    q_value = sat8(golden_l1(x, y, ch));
                    layer1_act[x][y][ch] = q_value;
                end else begin
                    q_value = sat8(golden_l2(x, y, ch));
                end
                exp_data[lane*DATA_W +: DATA_W] = DATA_W'(q_value);
            end

            if (phase == 1) begin
                check(gb_ao_wr_addr_o == GB_ADDR_W'(ACT2_BASE + base_elem),
                      $sformatf("layer1 word %0d addr expected=0x%0h got=0x%0h",
                                word_idx, ACT2_BASE + base_elem, gb_ao_wr_addr_o));
            end else begin
                check(gb_ao_wr_addr_o == GB_ADDR_W'(ACT3_BASE + base_elem),
                      $sformatf("layer2 word %0d addr expected=0x%0h got=0x%0h",
                                word_idx, ACT3_BASE + base_elem, gb_ao_wr_addr_o));
            end
            check(gb_ao_wr_mask_o == {MASK_W{1'b1}},
                  $sformatf("phase %0d word %0d mask mismatch", phase, word_idx));
            check(gb_ao_wr_data_o == exp_data,
                  $sformatf("phase %0d word %0d data mismatch", phase, word_idx));
        end
    endtask

    initial begin
        fail_cnt = 0;
        phase = 0;
        write_cnt = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        start_i = 1'b0;
        act_base_addr_i = GB_ADDR_W'(ACT1_BASE);
        wgt_base_addr_i = GB_ADDR_W'(WGT1_BASE);
        out_base_addr_i = GB_ADDR_W'(ACT2_BASE);
        output_elements_i = ELEM_CNT_W'(L1_OUTPUTS);
        num_filter_code_i = 2'd1;       // 128-channel HWC stride
        ifmap_size_code_i = 3'd3;       // 56x56 input
        stride_i = 1'b1;
        pad_i = 1'b1;
        current_num_filter_i = C;
        post_mode_i = 3'd0;             // bypass saturate for this top-level path test
        residual_en_i = 1'b0;
        residual_i = '0;
        output_zero_point_i = '0;

        for (int addr = 0; addr < MEM_DEPTH; addr++) begin
            ao_mem[addr] = '0;
            wgt_mem[addr] = '0;
        end

        for (int x_i = 0; x_i < L1_IN_SIZE; x_i++) begin
            for (int y_i = 0; y_i < L1_IN_SIZE; y_i++) begin
                for (int tile = 0; tile < C; tile += LANES) begin
                    int addr;
                    addr = ACT1_BASE + (x_i * L1_IN_SIZE + y_i) * C + tile;
                    for (int lane_i = 0; lane_i < LANES; lane_i++) begin
                        set_word_lane(ao_mem[addr], lane_i, l1_act_value(x_i, y_i, tile + lane_i));
                    end
                end
            end
        end

        for (int pos = 0; pos < 9; pos++) begin
            for (int tile = 0; tile < C; tile += LANES) begin
                int addr1;
                int addr2;
                addr1 = WGT1_BASE + pos * C + tile;
                addr2 = WGT2_BASE + pos * C + tile;
                for (int lane_i = 0; lane_i < LANES; lane_i++) begin
                    set_word_lane(wgt_mem[addr1], lane_i, l1_wgt_value(pos, tile + lane_i));
                    set_word_lane(wgt_mem[addr2], lane_i, l2_wgt_value(pos, tile + lane_i));
                end
            end
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        phase = 1;
        write_cnt = 0;
        pulse_start();
        wait (done_o);
        repeat (2) @(posedge clk);
        check(write_cnt == L1_WORDS,
              $sformatf("layer1 write words expected=%0d got=%0d", L1_WORDS, write_cnt));

        phase = 2;
        write_cnt = 0;
        act_base_addr_i = GB_ADDR_W'(ACT2_BASE);
        wgt_base_addr_i = GB_ADDR_W'(WGT2_BASE);
        out_base_addr_i = GB_ADDR_W'(ACT3_BASE);
        output_elements_i = ELEM_CNT_W'(L2_OUTPUTS);
        ifmap_size_code_i = 3'd2;       // 28x28 input
        stride_i = 1'b0;
        repeat (4) @(posedge clk);
        pulse_start();
        wait (done_o);
        repeat (2) @(posedge clk);
        check(write_cnt == L2_WORDS,
              $sformatf("layer2 write words expected=%0d got=%0d", L2_WORDS, write_cnt));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_top DW CSV FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_top DW CSV PASSED l1_words=%0d l2_words=%0d",
                 L1_WORDS, L2_WORDS);
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
            if (gb_ao_wr_valid_o) begin
                for (int lane_i = 0; lane_i < LANES; lane_i++) begin
                    if (gb_ao_wr_mask_o[lane_i]) begin
                        ao_mem[gb_ao_wr_addr_o][lane_i*DATA_W +: DATA_W] <=
                            gb_ao_wr_data_o[lane_i*DATA_W +: DATA_W];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && gb_ao_wr_valid_o) begin
            check_write_word(write_cnt);
            write_cnt++;
        end
    end
endmodule
