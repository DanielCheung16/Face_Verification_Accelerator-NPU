`timescale 1ns/1ps
import layer_defs_pkg::*;

module tb_layer_switcher;
    parameter int ROW = 14;
    parameter int COL = 16;
    parameter int K_MAX = 512;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int OUT_W = 8;
    parameter int MULT_W = 32;
    parameter int SHIFT_W = 6;
    parameter int DIM_W = 16;
    parameter int PARAM_ADDR_W = 16;
    parameter int GB_DATA_W = 128;
    parameter int AO_DEPTH = 8192;
    parameter int WGT_DEPTH = 8192;
    parameter int NUM_DEV = 2;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 200;

    localparam int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX);
    localparam int K_SIZE_W = K_ADDR_W + 1;
    localparam int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W;
    localparam int AO_MASK_W = GB_DATA_W / DATA_W;
    localparam int GB_LANES = GB_DATA_W / DATA_W;

    localparam int MODE_PRELU = 1;
    localparam int MODE_RESIDUAL = 2;
    localparam int M28 = 28 * 28;
    localparam int L0_K = 128;
    localparam int L0_N = 64;
    localparam int L1_K = 64;
    localparam int L1_N = 128;
    localparam int AO_OUT_BASE = 1 << (GB_ADDR_W - 1);
    localparam int WGT1_BASE = L0_K * ((L0_N + GB_LANES - 1) / GB_LANES);
    localparam int L0_PARAM_BASE = 0;
    localparam int L1_PARAM_BASE = 64;
    localparam int L0_OUTPUT_ZERO_POINT = -18;
    localparam int L1_OUTPUT_ZERO_POINT = -77;

    logic clk;
    logic rst_n;
    logic sys_start;
    logic sys_done;

    logic start_o [NUM_DEV];
    logic busy_i  [NUM_DEV];
    logic done_i  [NUM_DEV];

    logic [K_ADDR_W:0]    k_size_o;
    logic [DIM_W-1:0]     m_size_o;
    logic [DIM_W-1:0]     n_size_o;
    logic [GB_ADDR_W-1:0] act_base_addr_o;
    logic [GB_ADDR_W-1:0] wgt_base_addr_o;
    logic [GB_ADDR_W-1:0] out_base_addr_o;
    logic residual_en_o;
    logic [GB_ADDR_W-1:0] residual_base_addr_o;
    logic [7:0] layer_idx_o;
    layer_type_t layer_type_o;

    logic [1:0]                    mode_o;
    logic [2:0]                    ifmap_size_code_o;
    logic [1:0]                    num_filter_code_o;
    logic                          stride_o;
    logic                          pad_o;
    logic signed [DATA_W-1:0]      pad_value_o;
    logic signed [OUT_W-1:0]       output_zero_point_o;
    logic [PARAM_ADDR_W-1:0]       bias_base_o;
    logic [PARAM_ADDR_W-1:0]       requant_mult_base_o;
    logic [PARAM_ADDR_W-1:0]       requant_shift_base_o;
    logic [PARAM_ADDR_W-1:0]       prelu_mult_base_o;
    logic [PARAM_ADDR_W-1:0]       prelu_shift_base_o;
    logic [PARAM_ADDR_W-1:0]       residual_mult_base_o;
    logic [PARAM_ADDR_W-1:0]       residual_shift_base_o;
    logic [PARAM_ADDR_W-1:0]       residual_zero_point_base_o;

    logic                     dev_act_rd_valid_i [NUM_DEV];
    logic [GB_ADDR_W-1:0]     dev_act_rd_addr_i [NUM_DEV];
    logic [GB_DATA_W-1:0]     dev_act_rd_data_o [NUM_DEV];
    logic                     dev_ao_wr_valid_i [NUM_DEV];
    logic [GB_ADDR_W-1:0]     dev_ao_wr_addr_i [NUM_DEV];
    logic [GB_DATA_W-1:0]     dev_ao_wr_data_i [NUM_DEV];
    logic [AO_MASK_W-1:0]     dev_ao_wr_mask_i [NUM_DEV];
    logic                     dev_wgt_rd_valid_i [NUM_DEV];
    logic [GB_ADDR_W-1:0]     dev_wgt_rd_addr_i [NUM_DEV];
    logic [GB_DATA_W-1:0]     dev_wgt_rd_data_o [NUM_DEV];

    logic                     gb_act_rd_valid_o;
    logic [GB_ADDR_W-1:0]     gb_act_rd_addr_o;
    logic [GB_DATA_W-1:0]     gb_act_rd_data_i;
    logic                     gb_ao_wr_valid_o;
    logic [GB_ADDR_W-1:0]     gb_ao_wr_addr_o;
    logic [GB_DATA_W-1:0]     gb_ao_wr_data_o;
    logic [AO_MASK_W-1:0]     gb_ao_wr_mask_o;
    logic                     gb_wgt_rd_valid_o;
    logic [GB_ADDR_W-1:0]     gb_wgt_rd_addr_o;
    logic [GB_DATA_W-1:0]     gb_wgt_rd_data_i;

    logic                     final_valid_o;
    logic [127:0]             final_vec_o;

    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    layer_switcher #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .NUM_DEV(NUM_DEV)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sys_start(sys_start),
        .sys_done(sys_done),
        .start_o(start_o),
        .busy_i(busy_i),
        .done_i(done_i),
        .k_size_o(k_size_o),
        .m_size_o(m_size_o),
        .n_size_o(n_size_o),
        .act_base_addr_o(act_base_addr_o),
        .wgt_base_addr_o(wgt_base_addr_o),
        .out_base_addr_o(out_base_addr_o),
        .residual_en_o(residual_en_o),
        .residual_base_addr_o(residual_base_addr_o),
        .layer_idx_o(layer_idx_o),
        .layer_type_o(layer_type_o),
        .mode_o(mode_o),
        .ifmap_size_code_o(ifmap_size_code_o),
        .num_filter_code_o(num_filter_code_o),
        .stride_o(stride_o),
        .pad_o(pad_o),
        .pad_value_o(pad_value_o),
        .output_zero_point_o(output_zero_point_o),
        .bias_base_o(bias_base_o),
        .requant_mult_base_o(requant_mult_base_o),
        .requant_shift_base_o(requant_shift_base_o),
        .prelu_mult_base_o(prelu_mult_base_o),
        .prelu_shift_base_o(prelu_shift_base_o),
        .residual_mult_base_o(residual_mult_base_o),
        .residual_shift_base_o(residual_shift_base_o),
        .residual_zero_point_base_o(residual_zero_point_base_o),
        .dev_act_rd_valid_i(dev_act_rd_valid_i),
        .dev_act_rd_addr_i(dev_act_rd_addr_i),
        .dev_act_rd_data_o(dev_act_rd_data_o),
        .dev_ao_wr_valid_i(dev_ao_wr_valid_i),
        .dev_ao_wr_addr_i(dev_ao_wr_addr_i),
        .dev_ao_wr_data_i(dev_ao_wr_data_i),
        .dev_ao_wr_mask_i(dev_ao_wr_mask_i),
        .dev_wgt_rd_valid_i(dev_wgt_rd_valid_i),
        .dev_wgt_rd_addr_i(dev_wgt_rd_addr_i),
        .dev_wgt_rd_data_o(dev_wgt_rd_data_o),
        .gb_act_rd_valid_o(gb_act_rd_valid_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_ao_wr_valid_o(gb_ao_wr_valid_o),
        .gb_ao_wr_addr_o(gb_ao_wr_addr_o),
        .gb_ao_wr_data_o(gb_ao_wr_data_o),
        .gb_ao_wr_mask_o(gb_ao_wr_mask_o),
        .gb_wgt_rd_valid_o(gb_wgt_rd_valid_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .final_valid_o(final_valid_o),
        .final_vec_o(final_vec_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic clear_device_ports();
        begin
            for (int d = 0; d < NUM_DEV; d++) begin
                busy_i[d] = 1'b0;
                done_i[d] = 1'b0;
                dev_act_rd_valid_i[d] = 1'b0;
                dev_act_rd_addr_i[d] = '0;
                dev_ao_wr_valid_i[d] = 1'b0;
                dev_ao_wr_addr_i[d] = '0;
                dev_ao_wr_data_i[d] = '0;
                dev_ao_wr_mask_i[d] = '0;
                dev_wgt_rd_valid_i[d] = 1'b0;
                dev_wgt_rd_addr_i[d] = '0;
            end
            gb_act_rd_data_i = '0;
            gb_wgt_rd_data_i = '0;
        end
    endtask

    task automatic expect_config(
        input int exp_k,
        input int exp_m,
        input int exp_n,
        input int exp_act_base,
        input int exp_wgt_base,
        input int exp_out_base,
        input int exp_mode,
        input int exp_param_base,
        input int exp_output_zero_point,
        input bit exp_residual_en,
        input string tag
    );
        begin
            check(k_size_o === K_SIZE_W'(exp_k), $sformatf("%s k_size", tag));
            check(m_size_o === DIM_W'(exp_m), $sformatf("%s m_size", tag));
            check(n_size_o === DIM_W'(exp_n), $sformatf("%s n_size", tag));
            check(act_base_addr_o === GB_ADDR_W'(exp_act_base), $sformatf("%s act_base", tag));
            check(wgt_base_addr_o === GB_ADDR_W'(exp_wgt_base), $sformatf("%s wgt_base", tag));
            check(out_base_addr_o === GB_ADDR_W'(exp_out_base), $sformatf("%s out_base", tag));
            check(residual_en_o === exp_residual_en, $sformatf("%s residual_en", tag));
            check(mode_o === 2'(exp_mode), $sformatf("%s mode", tag));
            check(ifmap_size_code_o === '0, $sformatf("%s ifmap_size_code", tag));
            check(num_filter_code_o === '0, $sformatf("%s num_filter_code", tag));
            check(stride_o === 1'b0, $sformatf("%s stride", tag));
            check(pad_o === 1'b0, $sformatf("%s pad", tag));
            check(pad_value_o === '0, $sformatf("%s pad_value", tag));
            check(output_zero_point_o === OUT_W'(exp_output_zero_point),
                  $sformatf("%s output_zero_point", tag));
            check(bias_base_o === PARAM_ADDR_W'(exp_param_base), $sformatf("%s bias_base", tag));
            check(requant_mult_base_o === PARAM_ADDR_W'(exp_param_base), $sformatf("%s requant_mult_base", tag));
            check(requant_shift_base_o === PARAM_ADDR_W'(exp_param_base), $sformatf("%s requant_shift_base", tag));
            check(prelu_mult_base_o === PARAM_ADDR_W'(exp_param_base), $sformatf("%s prelu_mult_base", tag));
            check(prelu_shift_base_o === PARAM_ADDR_W'(exp_param_base), $sformatf("%s prelu_shift_base", tag));
        end
    endtask

    task automatic expect_mux(input string tag);
        logic [GB_DATA_W-1:0] exp_ao_data;
        logic [GB_DATA_W-1:0] exp_act_data;
        logic [GB_DATA_W-1:0] exp_wgt_data;
        begin
            exp_ao_data = 128'h0123_4567_89ab_cdef_0123_4567_89ab_cdef;
            exp_act_data = 128'h1111_2222_3333_4444_5555_6666_7777_8888;
            exp_wgt_data = 128'h9999_aaaa_bbbb_cccc_dddd_eeee_ffff_0000;

            dev_act_rd_valid_i[0] = 1'b1;
            dev_act_rd_addr_i[0] = GB_ADDR_W'(13'h012);
            dev_ao_wr_valid_i[0] = 1'b1;
            dev_ao_wr_addr_i[0] = GB_ADDR_W'(13'h123);
            dev_ao_wr_data_i[0] = exp_ao_data;
            dev_ao_wr_mask_i[0] = AO_MASK_W'('h0f0f);
            dev_wgt_rd_valid_i[0] = 1'b1;
            dev_wgt_rd_addr_i[0] = GB_ADDR_W'(13'h234);

            dev_act_rd_valid_i[1] = 1'b1;
            dev_act_rd_addr_i[1] = GB_ADDR_W'(13'h777);
            dev_ao_wr_valid_i[1] = 1'b1;
            dev_ao_wr_addr_i[1] = GB_ADDR_W'(13'h778);
            dev_ao_wr_data_i[1] = '1;
            dev_ao_wr_mask_i[1] = '1;
            dev_wgt_rd_valid_i[1] = 1'b1;
            dev_wgt_rd_addr_i[1] = GB_ADDR_W'(13'h779);

            gb_act_rd_data_i = exp_act_data;
            gb_wgt_rd_data_i = exp_wgt_data;
            #1;

            check(gb_act_rd_valid_o === 1'b1, $sformatf("%s act valid", tag));
            check(gb_act_rd_addr_o === GB_ADDR_W'(13'h012), $sformatf("%s act addr", tag));
            check(dev_act_rd_data_o[0] === exp_act_data, $sformatf("%s act data dev0", tag));
            check(dev_act_rd_data_o[1] === '0, $sformatf("%s act data dev1", tag));

            check(gb_ao_wr_valid_o === 1'b1, $sformatf("%s ao wr valid", tag));
            check(gb_ao_wr_addr_o === GB_ADDR_W'(13'h123), $sformatf("%s ao wr addr", tag));
            check(gb_ao_wr_data_o === exp_ao_data, $sformatf("%s ao wr data", tag));
            check(gb_ao_wr_mask_o === AO_MASK_W'('h0f0f), $sformatf("%s ao wr mask", tag));

            check(gb_wgt_rd_valid_o === 1'b1, $sformatf("%s wgt valid", tag));
            check(gb_wgt_rd_addr_o === GB_ADDR_W'(13'h234), $sformatf("%s wgt addr", tag));
            check(dev_wgt_rd_data_o[0] === exp_wgt_data, $sformatf("%s wgt data dev0", tag));
            check(dev_wgt_rd_data_o[1] === '0, $sformatf("%s wgt data dev1", tag));

            clear_device_ports();
            #1;
        end
    endtask

    task automatic complete_active_layer();
        begin
            @(negedge clk);
            busy_i[0] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            done_i[0] = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            done_i[0] = 1'b0;
            busy_i[0] = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        sys_start = 1'b0;
        clear_device_ports();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        check(start_o[0] === 1'b0, "start_o[0] idle");
        check(gb_act_rd_valid_o === 1'b0, "gb act idle");

        @(negedge clk);
        sys_start = 1'b1;
        @(posedge clk);
        #1;
        check(start_o[0] === 1'b0, "config fetch cycle has no start pulse");
        @(posedge clk);
        #1;
        check(start_o[0] === 1'b1, "layer0 start pulse");
        check(start_o[1] === 1'b0, "layer0 inactive device start");
        expect_config(L0_K, M28, L0_N, 0, 0, AO_OUT_BASE, MODE_RESIDUAL,
                      L0_PARAM_BASE, L0_OUTPUT_ZERO_POINT, 1'b1, "layer0");

        @(posedge clk);
        #1;
        check(start_o[0] === 1'b0, "layer0 start is one cycle");
        expect_mux("layer0 mux");

        complete_active_layer();
        @(posedge clk);
        #1;
        check(start_o[0] === 1'b1, "layer1 start pulse");
        expect_config(L1_K, M28, L1_N, AO_OUT_BASE, WGT1_BASE, 0, MODE_PRELU,
                      L1_PARAM_BASE, L1_OUTPUT_ZERO_POINT, 1'b0, "layer1");

        @(posedge clk);
        #1;
        check(start_o[0] === 1'b0, "layer1 start is one cycle");
        expect_mux("layer1 mux");

        complete_active_layer();
        check(sys_done === 1'b1, "sys_done after final layer");
        check(final_valid_o === 1'b1, "final_valid after final layer");
        check(final_vec_o === '0, "final_vec placeholder is zero");
        check(gb_act_rd_valid_o === 1'b0, "gb act disabled in done");

        @(negedge clk);
        sys_start = 1'b0;
        @(posedge clk);
        #1;
        check(sys_done === 1'b0, "sys_done clears after sys_start drops");

        if (fail_cnt == 0) begin
            $display("[TB] layer_switcher PASSED");
        end else begin
            $fatal(1, "[TB] layer_switcher FAILED with %0d errors", fail_cnt);
        end
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end

endmodule
