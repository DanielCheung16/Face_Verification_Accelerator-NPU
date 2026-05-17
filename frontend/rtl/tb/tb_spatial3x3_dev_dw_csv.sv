`timescale 1ns/1ps

module tb_spatial3x3_dev_dw_csv;
    parameter int ADDR_W = 20;
    parameter int WORD_W = 128;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int ACT_DEPTH = 1;
    parameter int WGT_DEPTH = 8; // 128 channels / 16 lanes
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = WORD_W / DATA_W;
    localparam int C = 128;
    localparam int L1_IN_SIZE = 56;
    localparam int L1_OUT_SIZE = 28;
    localparam int L2_IN_SIZE = 28;
    localparam int L2_OUT_SIZE = 28;
    localparam int L1_OUTPUTS = L1_OUT_SIZE * L1_OUT_SIZE * C;
    localparam int L2_OUTPUTS = L2_OUT_SIZE * L2_OUT_SIZE * C;
    localparam int MEM_DEPTH = 600000;
    localparam int ACT1_BASE = 0;
    localparam int ACT2_BASE = 420000;
    localparam int WGT1_BASE = 0;
    localparam int WGT2_BASE = 4096;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic start_i;
    logic [ADDR_W-1:0] act_base_addr_i;
    logic [ADDR_W-1:0] wgt_base_addr_i;
    logic [1:0] num_filter_code_i;
    logic [2:0] ifmap_size_code_i;
    logic stride_i;
    logic pad_i;
    logic [($clog2(WGT_DEPTH*LANES)+1)-1:0] current_num_filter_i;
    logic gb_act_rd_en_o;
    logic [ADDR_W-1:0] gb_act_rd_addr_o;
    logic [WORD_W-1:0] gb_act_rd_data_i;
    logic gb_wgt_rd_en_o;
    logic [ADDR_W-1:0] gb_wgt_rd_addr_o;
    logic [WORD_W-1:0] gb_wgt_rd_data_i;
    logic signed [ACC_W-1:0] psum_o;
    logic valid_o;
    logic busy_o;
    logic done_o;

    logic [WORD_W-1:0] act_mem [MEM_DEPTH];
    logic [WORD_W-1:0] wgt_mem [MEM_DEPTH];
    int signed layer1_act [L1_OUT_SIZE][L1_OUT_SIZE][C];
    int signed expected_q[$];
    int fail_cnt;
    int out_cnt;
    int phase;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial3x3_dev #(
        .ADDR_W(ADDR_W),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .ACT_DEPTH(ACT_DEPTH),
        .WGT_DEPTH(WGT_DEPTH)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .pad_i(pad_i),
        .current_num_filter_i(current_num_filter_i),
        .gb_act_rd_en_o(gb_act_rd_en_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_en_o(gb_wgt_rd_en_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .psum_o(psum_o),
        .valid_o(valid_o),
        .busy_o(busy_o),
        .done_o(done_o)
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
        inout logic [WORD_W-1:0] word,
        input int lane,
        input int signed value
    );
        begin
            word[lane*DATA_W +: DATA_W] = DATA_W'(value);
        end
    endtask

    task automatic push_l1_expected;
        for (int x = 0; x < L1_OUT_SIZE; x++) begin
            for (int y = 0; y < L1_OUT_SIZE; y++) begin
                for (int tile = 0; tile < C; tile += LANES) begin
                    for (int lane = 0; lane < LANES; lane++) begin
                        expected_q.push_back(golden_l1(x, y, tile + lane));
                    end
                end
            end
        end
    endtask

    task automatic push_l2_expected;
        for (int x = 0; x < L2_OUT_SIZE; x++) begin
            for (int y = 0; y < L2_OUT_SIZE; y++) begin
                for (int tile = 0; tile < C; tile += LANES) begin
                    for (int lane = 0; lane < LANES; lane++) begin
                        expected_q.push_back(golden_l2(x, y, tile + lane));
                    end
                end
            end
        end
    endtask

    task automatic pulse_start;
        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
    endtask

    initial begin
        fail_cnt = 0;
        out_cnt = 0;
        phase = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        start_i = 1'b0;
        act_base_addr_i = ADDR_W'(ACT1_BASE);
        wgt_base_addr_i = ADDR_W'(WGT1_BASE);
        num_filter_code_i = 2'd1;       // 128-channel HWC stride
        ifmap_size_code_i = 3'd3;       // 56x56 input for conv_23 DW
        stride_i = 1'b1;
        pad_i = 1'b1;
        current_num_filter_i = C;

        for (int addr = 0; addr < MEM_DEPTH; addr++) begin
            act_mem[addr] = '0;
            wgt_mem[addr] = '0;
        end

        for (int x = 0; x < L1_IN_SIZE; x++) begin
            for (int y = 0; y < L1_IN_SIZE; y++) begin
                for (int tile = 0; tile < C; tile += LANES) begin
                    int addr;
                    addr = ACT1_BASE + (x * L1_IN_SIZE + y) * C + tile;
                    for (int lane = 0; lane < LANES; lane++) begin
                        set_word_lane(act_mem[addr], lane, l1_act_value(x, y, tile + lane));
                    end
                end
            end
        end

        for (int x = 0; x < L1_OUT_SIZE; x++) begin
            for (int y = 0; y < L1_OUT_SIZE; y++) begin
                for (int ch = 0; ch < C; ch++) begin
                    layer1_act[x][y][ch] = 0;
                end
            end
        end

        for (int pos = 0; pos < 9; pos++) begin
            for (int tile = 0; tile < C; tile += LANES) begin
                int addr1;
                int addr2;
                addr1 = WGT1_BASE + pos * C + tile;
                addr2 = WGT2_BASE + pos * C + tile;
                for (int lane = 0; lane < LANES; lane++) begin
                    set_word_lane(wgt_mem[addr1], lane, l1_wgt_value(pos, tile + lane));
                    set_word_lane(wgt_mem[addr2], lane, l2_wgt_value(pos, tile + lane));
                end
            end
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        phase = 1;
        out_cnt = 0;
        push_l1_expected();
        pulse_start();
        wait (out_cnt == L1_OUTPUTS);
        wait (!busy_o);
        check(expected_q.size() == 0,
              $sformatf("layer1 expected queue not empty: %0d", expected_q.size()));

        phase = 2;
        out_cnt = 0;
        act_base_addr_i = ADDR_W'(ACT2_BASE);
        wgt_base_addr_i = ADDR_W'(WGT2_BASE);
        ifmap_size_code_i = 3'd2;       // 28x28 input for conv_3 DW
        stride_i = 1'b0;
        push_l2_expected();
        repeat (4) @(posedge clk);
        pulse_start();
        wait (out_cnt == L2_OUTPUTS);
        wait (!busy_o);
        check(expected_q.size() == 0,
              $sformatf("layer2 expected queue not empty: %0d", expected_q.size()));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial3x3_dev DW CSV FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial3x3_dev DW CSV PASSED l1_outputs=%0d l2_outputs=%0d",
                 L1_OUTPUTS, L2_OUTPUTS);
        $finish;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            gb_act_rd_data_i <= '0;
            gb_wgt_rd_data_i <= '0;
        end else begin
            if (gb_act_rd_en_o) begin
                gb_act_rd_data_i <= act_mem[gb_act_rd_addr_o];
            end
            if (gb_wgt_rd_en_o) begin
                gb_wgt_rd_data_i <= wgt_mem[gb_wgt_rd_addr_o];
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && valid_o) begin
            int signed exp;
            check(expected_q.size() > 0, "unexpected extra valid_o");
            if (expected_q.size() > 0) begin
                exp = expected_q.pop_front();
                check(psum_o === ACC_W'(exp),
                      $sformatf("phase %0d output %0d expected=%0d got=%0d",
                                phase, out_cnt, exp, psum_o));
            end

            if (phase == 1) begin
                int x;
                int y;
                int tile_group;
                int lane;
                int ch;
                int addr;
                int signed q_value;

                lane = out_cnt % LANES;
                tile_group = (out_cnt / LANES) % (C / LANES);
                ch = tile_group * LANES + lane;
                y = (out_cnt / C) % L1_OUT_SIZE;
                x = out_cnt / (C * L1_OUT_SIZE);
                addr = ACT2_BASE + (x * L1_OUT_SIZE + y) * C + tile_group * LANES;
                q_value = sat8(psum_o);
                layer1_act[x][y][ch] = q_value;
                set_word_lane(act_mem[addr], lane, q_value);
            end

            out_cnt++;
        end
    end
endmodule
