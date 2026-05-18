`timescale 1ns/1ps

module tb_spatial_top_c_ref;
    parameter int GB_ADDR_W = 20;
    parameter int GB_DATA_W = 128;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int ACT_DEPTH = 1;
    parameter int WGT_DEPTH = 4; // qface op1: 64 channels / 16 lanes
    parameter int ELEM_CNT_W = 32;
    parameter int HALF_CYCLE_TIME = 5;

    localparam int LANES = GB_DATA_W / DATA_W;
    localparam int MASK_W = LANES;
    localparam int C = 64;
    localparam int OUT_SIZE = 56;
    localparam int OUTPUTS = OUT_SIZE * OUT_SIZE * C;
    localparam int OUTPUT_WORDS = OUTPUTS / LANES;
    localparam int MEM_DEPTH = 600000;
    localparam int PARAM_DEPTH = 128;
    localparam int PARAM_ADDR_W = 16;
    localparam int ACT_BASE = 0;
    localparam int WGT_BASE = 0;
    localparam int OUT_BASE = 300000;

    localparam string AO_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_ao_init.txt";
    localparam string WGT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_wgt_init.txt";
    localparam string EXPECTED_FILE = "gold_models/qface_c/generated/spatial_top_dw_expected.txt";
    localparam string BIAS_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_bias.hex";
    localparam string REQUANT_MULT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_requant_mult.hex";
    localparam string REQUANT_SHIFT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_requant_shift.hex";
    localparam string PRELU_MULT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_prelu_mult.hex";
    localparam string PRELU_SHIFT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_prelu_shift.hex";
    localparam string RESIDUAL_MULT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_residual_mult.hex";
    localparam string RESIDUAL_SHIFT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_residual_shift.hex";
    localparam string RESIDUAL_ZERO_POINT_INIT_FILE = "gold_models/qface_c/generated/spatial_top_dw_residual_zero_point.hex";

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
        .pad_value_i(-8'sd31),
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

    // Parameter memory loaded from the C golden dump. The scheduler reads one
    // channel row per spatial psum and aligns the ROM latency before postprocess.
    quant_param_mem #(
        .COMMON_PARAM_DEPTH(PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(PARAM_DEPTH),
        .COMMON_PARAM_ADDR_W(PARAM_ADDR_W),
        .PRELU_PARAM_ADDR_W(PARAM_ADDR_W),
        .RESIDUAL_PARAM_ADDR_W(PARAM_ADDR_W),
        .BIAS_INIT_FILE(BIAS_INIT_FILE),
        .REQUANT_MULT_INIT_FILE(REQUANT_MULT_INIT_FILE),
        .REQUANT_SHIFT_INIT_FILE(REQUANT_SHIFT_INIT_FILE),
        .PRELU_MULT_INIT_FILE(PRELU_MULT_INIT_FILE),
        .PRELU_SHIFT_INIT_FILE(PRELU_SHIFT_INIT_FILE),
        .RESIDUAL_MULT_INIT_FILE(RESIDUAL_MULT_INIT_FILE),
        .RESIDUAL_SHIFT_INIT_FILE(RESIDUAL_SHIFT_INIT_FILE),
        .RESIDUAL_ZERO_POINT_INIT_FILE(RESIDUAL_ZERO_POINT_INIT_FILE)
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

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic load_records(input string path, ref logic [GB_DATA_W-1:0] mem [MEM_DEPTH]);
        int fd;
        int code;
        int addr;
        logic [GB_DATA_W-1:0] word;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $fatal(1, "failed to open %s", path);
            end

            while (!$feof(fd)) begin
                code = $fscanf(fd, "%d %h\n", addr, word);
                if (code == 2) begin
                    mem[addr] = word;
                end
            end
            $fclose(fd);
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
        write_cnt = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        start_i = 1'b0;
        act_base_addr_i = GB_ADDR_W'(ACT_BASE);
        wgt_base_addr_i = GB_ADDR_W'(WGT_BASE);
        out_base_addr_i = GB_ADDR_W'(OUT_BASE);
        output_elements_i = ELEM_CNT_W'(OUTPUTS);
        num_filter_code_i = 2'd0;       // 64 channels
        ifmap_size_code_i = 3'd3;       // 56x56
        stride_i = 1'b0;
        pad_i = 1'b1;
        current_num_filter_i = C;
        post_mode_i = 3'd2;             // qface op1: PReLU + requant.
        residual_en_i = 1'b0;
        residual_i = '0;
        output_zero_point_i = -32'sd57;

        for (int addr = 0; addr < MEM_DEPTH; addr++) begin
            ao_mem[addr] = '0;
            wgt_mem[addr] = '0;
            exp_mem[addr] = '0;
        end

        load_records(AO_INIT_FILE, ao_mem);
        load_records(WGT_INIT_FILE, wgt_mem);
        load_records(EXPECTED_FILE, exp_mem);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        pulse_start();
        wait (done_o);
        repeat (2) @(posedge clk);

        check(write_cnt == OUTPUT_WORDS,
              $sformatf("write words expected=%0d got=%0d", OUTPUT_WORDS, write_cnt));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_top C-ref FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_top C-ref PASSED words=%0d", write_cnt);
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
                for (int lane = 0; lane < LANES; lane++) begin
                    if (gb_ao_wr_mask_o[lane]) begin
                        ao_mem[gb_ao_wr_addr_o][lane*DATA_W +: DATA_W] <=
                            gb_ao_wr_data_o[lane*DATA_W +: DATA_W];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && gb_ao_wr_valid_o) begin
            check(gb_ao_wr_addr_o == GB_ADDR_W'(OUT_BASE + write_cnt),
                  $sformatf("addr mismatch word=%0d expected=0x%0h got=0x%0h",
                            write_cnt, OUT_BASE + write_cnt, gb_ao_wr_addr_o));
            check(gb_ao_wr_mask_o == {MASK_W{1'b1}},
                  $sformatf("mask mismatch word=%0d got=0x%0h", write_cnt, gb_ao_wr_mask_o));
            check(gb_ao_wr_data_o == exp_mem[gb_ao_wr_addr_o],
                  $sformatf("data mismatch word=%0d addr=0x%0h expected=%0h got=%0h",
                            write_cnt, gb_ao_wr_addr_o, exp_mem[gb_ao_wr_addr_o], gb_ao_wr_data_o));
            write_cnt++;
        end
    end
endmodule
