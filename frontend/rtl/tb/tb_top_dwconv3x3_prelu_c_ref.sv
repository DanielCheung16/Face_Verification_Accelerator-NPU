`timescale 1ns/1ps

module tb_top_dwconv3x3_prelu_c_ref;
    parameter int ROW = 14;
    parameter int COL = 16;
    parameter int K_MAX = 512;
    parameter int DATA_W = 8;
    parameter int GB_DATA_W = 128;
    parameter int AO_DEPTH = 600000;
    parameter int WGT_DEPTH = 2048;
    parameter int SPATIAL_WGT_DEPTH = 4;
    parameter int PARAM_DEPTH = 128;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 1000000;

    localparam int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam int MASK_W = GB_DATA_W / DATA_W;
    localparam int LANES = MASK_W;
    localparam int OUT_SIZE = 56;
    localparam int C = 64;
    localparam int OUTPUT_WORDS = (OUT_SIZE * OUT_SIZE * C) / LANES;
    localparam int OUT_BASE = 300000;

    localparam string GOLD_DIR = "gold_models/qface_c/generated";
    localparam string AO_INIT_FILE = {GOLD_DIR, "/spatial_top_dw_ao_init.txt"};
    localparam string WGT_INIT_FILE = {GOLD_DIR, "/spatial_top_dw_wgt_init.txt"};
    localparam string EXPECTED_FILE = {GOLD_DIR, "/spatial_top_dw_expected.txt"};

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

    logic [GB_DATA_W-1:0] expected [AO_DEPTH];
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
        .AO_TRUE_DUAL_PORT(1'b0),
        .WGT_TRUE_DUAL_PORT(1'b0),
        .COMMON_PARAM_DEPTH(PARAM_DEPTH),
        .PRELU_PARAM_DEPTH(PARAM_DEPTH),
        .RESIDUAL_PARAM_DEPTH(PARAM_DEPTH),
        .SPATIAL_WGT_DEPTH(SPATIAL_WGT_DEPTH),
        .LAYER_CONFIG_PROFILE(4),
        .QUANT_BIAS_INIT_FILE({GOLD_DIR, "/spatial_top_dw_bias.hex"}),
        .QUANT_REQUANT_MULT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_requant_mult.hex"}),
        .QUANT_REQUANT_SHIFT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_requant_shift.hex"}),
        .QUANT_PRELU_MULT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_prelu_mult.hex"}),
        .QUANT_PRELU_SHIFT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_prelu_shift.hex"}),
        .QUANT_RESIDUAL_MULT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_residual_mult.hex"}),
        .QUANT_RESIDUAL_SHIFT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_residual_shift.hex"}),
        .QUANT_RESIDUAL_ZERO_POINT_INIT_FILE({GOLD_DIR, "/spatial_top_dw_residual_zero_point.hex"})
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

    task automatic load_records_to_ao(input string path);
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
                    dut.u_ao_gb.GEN_SDP.u_sram.mem[addr] = word;
                end
            end
            $fclose(fd);
        end
    endtask

    task automatic load_records_to_wgt(input string path);
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
                    dut.u_wgt_gb.GEN_SDP.u_sram.mem[addr] = word;
                end
            end
            $fclose(fd);
        end
    endtask

    task automatic load_records_to_expected(input string path);
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
                    expected[addr] = word;
                end
            end
            $fclose(fd);
        end
    endtask

    task automatic load_hex_images();
        begin
            for (int addr = 0; addr < AO_DEPTH; addr++) begin
                dut.u_ao_gb.GEN_SDP.u_sram.mem[addr] = '0;
                expected[addr] = '0;
            end
            for (int addr = 0; addr < WGT_DEPTH; addr++) begin
                dut.u_wgt_gb.GEN_SDP.u_sram.mem[addr] = '0;
            end

            $display("[TB] loading %s", AO_INIT_FILE);
            load_records_to_ao(AO_INIT_FILE);
            $display("[TB] loading %s", WGT_INIT_FILE);
            load_records_to_wgt(WGT_INIT_FILE);
            $display("[TB] loading %s", EXPECTED_FILE);
            load_records_to_expected(EXPECTED_FILE);
        end
    endtask

    task automatic compare_final();
        int addr;
        logic [GB_DATA_W-1:0] got;
        logic [GB_DATA_W-1:0] exp;
        begin
            for (int word = 0; word < OUTPUT_WORDS; word++) begin
                addr = OUT_BASE + word * LANES;
                got = dut.u_ao_gb.GEN_SDP.u_sram.mem[addr];
                exp = expected[addr];
                check(got === exp,
                      $sformatf("DW final word=%0d addr=%0d expected=0x%032h got=0x%032h",
                                word, addr, exp, got));
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
            $fatal(1, "[TB] top DWConv3x3 + PReLU + requant FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] top DWConv3x3 + PReLU + requant PASSED words=%0d", OUTPUT_WORDS);
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
