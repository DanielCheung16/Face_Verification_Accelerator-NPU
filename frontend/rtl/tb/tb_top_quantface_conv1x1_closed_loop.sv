`timescale 1ns/1ps

module tb_top_quantface_conv1x1_closed_loop;
    parameter int ROW = 14;
    parameter int COL = 16;
    parameter int K_MAX = 512;
    parameter int DATA_W = 8;
    parameter int GB_DATA_W = 128;
    parameter int AO_DEPTH = 65536;
    parameter int WGT_DEPTH = 65536;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 3000000;

    localparam int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam int MASK_W = GB_DATA_W / DATA_W;
    localparam int M_SIZE = 28 * 28;
    localparam int FINAL_N = 128;
    localparam int FINAL_N_TILES = (FINAL_N + COL - 1) / COL;
    localparam int FINAL_BASE = 0;

    localparam string GOLD_DIR = "gold_models/quantface_conv1x1_c_ref/out";
    localparam string AO_INIT_HEX = {GOLD_DIR, "/quantface_conv1x1_c_ao_init.hex"};
    localparam string WGT_INIT_HEX = {GOLD_DIR, "/quantface_conv1x1_c_wgt_init.hex"};
    localparam string GOLDEN_HEX = {GOLD_DIR, "/quantface_conv1x1_c_golden.hex"};
    localparam string DUT_AO_FINAL_HEX = {GOLD_DIR, "/quantface_conv1x1_c_dut_ao_final.hex"};

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

    logic [GB_DATA_W-1:0] golden [AO_DEPTH];
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
            $display("[TB] loading %s", AO_INIT_HEX);
            $readmemh(AO_INIT_HEX, dut.u_ao_gb.GEN_SDP.u_sram.mem);
            $display("[TB] loading %s", WGT_INIT_HEX);
            $readmemh(WGT_INIT_HEX, dut.u_wgt_gb.GEN_SDP.u_sram.mem);
            $display("[TB] loading %s", GOLDEN_HEX);
            $readmemh(GOLDEN_HEX, golden);
        end
    endtask

    task automatic dump_final_ao();
        int fd;
        begin
            fd = $fopen(DUT_AO_FINAL_HEX, "w");
            check(fd != 0, $sformatf("failed to open %s", DUT_AO_FINAL_HEX));
            if (fd != 0) begin
                for (int addr = 0; addr < AO_DEPTH; addr++) begin
                    $fdisplay(fd, "%032h", dut.u_ao_gb.GEN_SDP.u_sram.mem[addr]);
                end
                $fclose(fd);
            end
        end
    endtask

    task automatic compare_final();
        int addr;
        logic [GB_DATA_W-1:0] got;
        logic [GB_DATA_W-1:0] exp;
        begin
            for (int m = 0; m < M_SIZE; m++) begin
                for (int nt = 0; nt < FINAL_N_TILES; nt++) begin
                    addr = FINAL_BASE + m * FINAL_N_TILES + nt;
                    got = dut.u_ao_gb.GEN_SDP.u_sram.mem[addr];
                    exp = golden[addr];
                    check(got === exp,
                          $sformatf("AO final addr=%0d m=%0d nt=%0d expected=0x%032h got=0x%032h",
                                    addr, m, nt, exp, got));
                end
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

        dump_final_ao();
        compare_final();

        @(negedge clk);
        sys_start = 1'b0;
        @(posedge clk);

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] top QuantFace conv1x1 closed-loop FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] top QuantFace conv1x1 closed-loop PASSED");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
