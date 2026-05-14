`timescale 1ns/1ps

module tb_top_smoke;
    parameter int ROW = 14;
    parameter int COL = 16;
    parameter int K_MAX = 512;
    parameter int DATA_W = 8;
    parameter int GB_DATA_W = 128;
    parameter int AO_DEPTH = 8192;
    parameter int WGT_DEPTH = 8192;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 200;

    localparam int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam int MASK_W = GB_DATA_W / DATA_W;

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
        .WGT_TRUE_DUAL_PORT(1'b1)
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

    task automatic host_write_ao(input int addr, input logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_ao_wr_en = 1'b1;
            host_ao_addr = addr[AO_ADDR_W-1:0];
            host_ao_wr_data = data;
            host_ao_wr_mask = '1;
            @(negedge clk);
            host_ao_wr_en = 1'b0;
        end
    endtask

    task automatic host_read_ao(input int addr, output logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_ao_rd_en = 1'b1;
            host_ao_addr = addr[AO_ADDR_W-1:0];
            @(posedge clk);
            #1;
            data = host_ao_rd_data;
            @(negedge clk);
            host_ao_rd_en = 1'b0;
        end
    endtask

    task automatic host_write_wgt(input int addr, input logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_wgt_en = 1'b1;
            host_wgt_wr_en = 1'b1;
            host_wgt_addr = addr[WGT_ADDR_W-1:0];
            host_wgt_wr_data = data;
            host_wgt_wr_mask = '1;
            @(negedge clk);
            host_wgt_en = 1'b0;
            host_wgt_wr_en = 1'b0;
        end
    endtask

    task automatic host_read_wgt(input int addr, output logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_wgt_en = 1'b1;
            host_wgt_wr_en = 1'b0;
            host_wgt_addr = addr[WGT_ADDR_W-1:0];
            @(posedge clk);
            #1;
            data = host_wgt_rd_data;
            @(negedge clk);
            host_wgt_en = 1'b0;
        end
    endtask

    initial begin
        logic [GB_DATA_W-1:0] got;

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

        check(sys_done === 1'b0, "sys_done idle low");
        check(final_valid === 1'b0, "final_valid idle low");

        host_write_ao(3, 128'h0123_4567_89ab_cdef_1111_2222_3333_4444);
        host_read_ao(3, got);
        check(got === 128'h0123_4567_89ab_cdef_1111_2222_3333_4444,
              $sformatf("AO host readback expected 0x%032h got 0x%032h",
                        128'h0123_4567_89ab_cdef_1111_2222_3333_4444, got));

        host_write_wgt(7, 128'haaaa_bbbb_cccc_dddd_eeee_ffff_0000_1234);
        host_read_wgt(7, got);
        check(got === 128'haaaa_bbbb_cccc_dddd_eeee_ffff_0000_1234,
              $sformatf("WGT host readback expected 0x%032h got 0x%032h",
                        128'haaaa_bbbb_cccc_dddd_eeee_ffff_0000_1234, got));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] top smoke FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] top smoke PASSED");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
