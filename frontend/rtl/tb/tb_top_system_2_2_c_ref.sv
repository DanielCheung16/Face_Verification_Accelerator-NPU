`timescale 1ns/1ps

module tb_top_system_2_2_c_ref;
    parameter int PROFILE = 5;
    parameter int ROW = 14;
    parameter int COL = 16;
    parameter int K_MAX = 512;
    parameter int DATA_W = 8;
    parameter int GB_DATA_W = 128;
    parameter int AO_DEPTH = 65536;
    parameter int WGT_DEPTH = 8192;
    parameter int SPATIAL_WGT_DEPTH = 8;
    parameter int PARAM_DEPTH = 9792;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 5000000;

    localparam int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam int MASK_W = GB_DATA_W / DATA_W;
    localparam int OUT_SIZE = (PROFILE == 12) ? 1 : ((PROFILE == 10) ? 56 : 28);
    localparam int OUT_C = (PROFILE == 12) ? 128 : 64;
    localparam int OUTPUT_WORDS = (OUT_SIZE * OUT_SIZE * OUT_C + MASK_W - 1) / MASK_W;
    localparam int OUT_BASE = 40000;

    localparam string GOLD_DIR = (PROFILE == 12) ?
        "gold_models/qface_c/generated/system_4_1_gdconv7x7_fc" :
        ((PROFILE == 10) ?
        "gold_models/qface_c/generated/system_3_2_conv3x3_dw" :
        ((PROFILE == 8) ?
        "gold_models/qface_c/generated/system_2_4_stride2_dw_conv1x1" :
        ((PROFILE == 6) ?
            "gold_models/qface_c/generated/system_2_2_seq1" :
            "gold_models/qface_c/generated/system_2_2_seq0")));
    localparam string AO_INIT_FILE = {GOLD_DIR, "/system_2_2_ao_init.hex"};
    localparam string WGT_INIT_FILE = {GOLD_DIR, "/system_2_2_wgt_init.hex"};
    localparam string EXPECTED_FILE = {GOLD_DIR, "/system_2_2_golden.hex"};

    logic clk;
    logic rst_n;
    logic sys_start;
    logic sys_done;
    logic final_valid;
    logic [127:0] final_vec;

    logic host_ao_rd_en;
    logic host_ao_wr_en;
    logic [AO_ADDR_W-1:0] host_ao_addr;
    logic [GB_DATA_W-1:0] host_ao_wr_data;
    logic [MASK_W-1:0] host_ao_wr_mask;
    logic [GB_DATA_W-1:0] host_ao_rd_data;

    logic host_wgt_en;
    logic host_wgt_wr_en;
    logic [WGT_ADDR_W-1:0] host_wgt_addr;
    logic [GB_DATA_W-1:0] host_wgt_wr_data;
    logic [MASK_W-1:0] host_wgt_wr_mask;
    logic [GB_DATA_W-1:0] host_wgt_rd_data;

    logic [GB_DATA_W-1:0] expected [0:AO_DEPTH-1];
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .DATA_W(DATA_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH),
        .NUM_DEV(3),
        .AO_TRUE_DUAL_PORT(1'b0),
        .WGT_TRUE_DUAL_PORT(1'b0),
        .COMMON_PARAM_DEPTH(PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(PARAM_DEPTH),
        .SPATIAL_WGT_DEPTH(SPATIAL_WGT_DEPTH),
        .LAYER_CONFIG_PROFILE(PROFILE),
        .QUANT_BIAS_INIT_FILE({GOLD_DIR, "/quant_param_bias.hex"}),
        .QUANT_REQUANT_MULT_INIT_FILE({GOLD_DIR, "/quant_param_requant_mult.hex"}),
        .QUANT_REQUANT_SHIFT_INIT_FILE({GOLD_DIR, "/quant_param_requant_shift.hex"}),
        .QUANT_PRELU_MULT_INIT_FILE({GOLD_DIR, "/quant_param_prelu_mult.hex"}),
        .QUANT_PRELU_SHIFT_INIT_FILE({GOLD_DIR, "/quant_param_prelu_shift.hex"}),
        .QUANT_RESIDUAL_MULT_INIT_FILE({GOLD_DIR, "/quant_param_residual_mult.hex"}),
        .QUANT_RESIDUAL_SHIFT_INIT_FILE({GOLD_DIR, "/quant_param_residual_shift.hex"}),
        .QUANT_RESIDUAL_ZERO_POINT_INIT_FILE({GOLD_DIR, "/quant_param_residual_zero_point.hex"})
    ) dut (
        .aclk(clk),
        .aresetn(rst_n),
        .sys_start(sys_start),
        .sys_done(sys_done),
        .final_valid_o(final_valid),
        .final_vec_o(final_vec),
        .host_ao_rd_en_i(host_ao_rd_en),
        .host_ao_wr_en_i(host_ao_wr_en),
        .host_ao_addr_i(host_ao_addr),
        .host_ao_wr_data_i(host_ao_wr_data),
        .host_ao_wr_mask_i(host_ao_wr_mask),
        .host_ao_rd_data_o(host_ao_rd_data),
        .host_wgt_en_i(host_wgt_en),
        .host_wgt_wr_en_i(host_wgt_wr_en),
        .host_wgt_addr_i(host_wgt_addr),
        .host_wgt_wr_data_i(host_wgt_wr_data),
        .host_wgt_wr_mask_i(host_wgt_wr_mask),
        .host_wgt_rd_data_o(host_wgt_rd_data)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic load_hex_images();
        begin
            $display("[TB] PROFILE=%0d GOLD_DIR=%s", PROFILE, GOLD_DIR);
            $display("[TB] loading %s", AO_INIT_FILE);
            $readmemh(AO_INIT_FILE, dut.u_ao_gb.GEN_SDP.u_sram.mem);
            $display("[TB] loading %s", WGT_INIT_FILE);
            $readmemh(WGT_INIT_FILE, dut.u_wgt_gb.GEN_SDP.u_sram.mem);
            $display("[TB] loading %s", EXPECTED_FILE);
            $readmemh(EXPECTED_FILE, expected);
        end
    endtask

    task automatic compare_final();
        int addr;
        logic [GB_DATA_W-1:0] got;
        logic [GB_DATA_W-1:0] exp;
        begin
            for (int word = 0; word < OUTPUT_WORDS; word++) begin
                addr = OUT_BASE + word;
                got = dut.u_ao_gb.GEN_SDP.u_sram.mem[addr];
                exp = expected[addr];
                check(got === exp,
                      $sformatf("system profile=%0d word=%0d addr=%0d expected=0x%032h got=0x%032h",
                                PROFILE, word, addr, exp, got));
            end
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        sys_start = 1'b0;
        host_ao_rd_en = 1'b0;
        host_ao_wr_en = 1'b0;
        host_ao_addr = '0;
        host_ao_wr_data = '0;
        host_ao_wr_mask = '0;
        host_wgt_en = 1'b0;
        host_wgt_wr_en = 1'b0;
        host_wgt_addr = '0;
        host_wgt_wr_data = '0;
        host_wgt_wr_mask = '0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        load_hex_images();

        @(negedge clk);
        sys_start = 1'b1;
        wait (sys_done === 1'b1);
        @(posedge clk);
        check(final_valid === 1'b1, "final_valid asserted with sys_done");

        compare_final();

        @(negedge clk);
        sys_start = 1'b0;
        @(posedge clk);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] system verification profile=%0d FAILED fail=%0d", PROFILE, fail_cnt);
        end
        $display("[TB] system verification profile=%0d PASSED words=%0d", PROFILE, OUTPUT_WORDS);
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
