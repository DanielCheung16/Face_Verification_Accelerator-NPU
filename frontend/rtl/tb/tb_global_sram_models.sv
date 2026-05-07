`timescale 1ns/1ps

module tb_global_sram_models;
    parameter int DATA_W = 128;
    parameter int DEPTH = 64;
    parameter int BYTE_W = 8;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 10000;

    localparam int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int WMASK_W = (DATA_W + BYTE_W - 1) / BYTE_W;

    logic clk;
    logic rst_n;
    int fail_cnt;

    logic                  w_load_en;
    logic                  w_load_wr_en;
    logic [ADDR_W-1:0]     w_load_addr;
    logic [DATA_W-1:0]     w_load_wr_data;
    logic [WMASK_W-1:0]    w_load_wr_mask;
    logic [DATA_W-1:0]     w_load_rd_data;
    logic                  w_acc_rd_en;
    logic [ADDR_W-1:0]     w_acc_rd_addr;
    logic [DATA_W-1:0]     w_acc_rd_data;

    logic                  ao_rd_en;
    logic [ADDR_W-1:0]     ao_rd_addr;
    logic [DATA_W-1:0]     ao_rd_data;
    logic                  ao_wr_en;
    logic [ADDR_W-1:0]     ao_wr_addr;
    logic [DATA_W-1:0]     ao_wr_data;
    logic [WMASK_W-1:0]    ao_wr_mask;
    logic                  ao_aux_en;
    logic                  ao_aux_wr_en;
    logic [ADDR_W-1:0]     ao_aux_addr;
    logic [DATA_W-1:0]     ao_aux_wr_data;
    logic [WMASK_W-1:0]    ao_aux_wr_mask;
    logic [DATA_W-1:0]     ao_aux_rd_data;

    logic                  t_a_en;
    logic                  t_a_wr_en;
    logic [ADDR_W-1:0]     t_a_addr;
    logic [DATA_W-1:0]     t_a_wr_data;
    logic [WMASK_W-1:0]    t_a_wr_mask;
    logic [DATA_W-1:0]     t_a_rd_data;
    logic                  t_b_en;
    logic                  t_b_wr_en;
    logic [ADDR_W-1:0]     t_b_addr;
    logic [DATA_W-1:0]     t_b_wr_data;
    logic [WMASK_W-1:0]    t_b_wr_mask;
    logic [DATA_W-1:0]     t_b_rd_data;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    weight_global_buffer #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH),
        .BYTE_W(BYTE_W),
        .TRUE_DUAL_PORT(1'b0)
    ) u_wgt_gb (
        .clk(clk),
        .rst_n(rst_n),
        .load_en_i(w_load_en),
        .load_wr_en_i(w_load_wr_en),
        .load_addr_i(w_load_addr),
        .load_wr_data_i(w_load_wr_data),
        .load_wr_mask_i(w_load_wr_mask),
        .load_rd_data_o(w_load_rd_data),
        .acc_rd_en_i(w_acc_rd_en),
        .acc_rd_addr_i(w_acc_rd_addr),
        .acc_rd_data_o(w_acc_rd_data)
    );

    activation_output_global_buffer #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH),
        .BYTE_W(BYTE_W),
        .TRUE_DUAL_PORT(1'b0)
    ) u_ao_gb (
        .clk(clk),
        .rst_n(rst_n),
        .rd_en_i(ao_rd_en),
        .rd_addr_i(ao_rd_addr),
        .rd_data_o(ao_rd_data),
        .wr_en_i(ao_wr_en),
        .wr_addr_i(ao_wr_addr),
        .wr_data_i(ao_wr_data),
        .wr_mask_i(ao_wr_mask),
        .aux_en_i(ao_aux_en),
        .aux_wr_en_i(ao_aux_wr_en),
        .aux_addr_i(ao_aux_addr),
        .aux_wr_data_i(ao_aux_wr_data),
        .aux_wr_mask_i(ao_aux_wr_mask),
        .aux_rd_data_o(ao_aux_rd_data)
    );

    sram_true_dual_port_model #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH),
        .BYTE_W(BYTE_W)
    ) u_tdp (
        .clk(clk),
        .rst_n(rst_n),
        .a_en_i(t_a_en),
        .a_wr_en_i(t_a_wr_en),
        .a_addr_i(t_a_addr),
        .a_wr_data_i(t_a_wr_data),
        .a_wr_mask_i(t_a_wr_mask),
        .a_rd_data_o(t_a_rd_data),
        .b_en_i(t_b_en),
        .b_wr_en_i(t_b_wr_en),
        .b_addr_i(t_b_addr),
        .b_wr_data_i(t_b_wr_data),
        .b_wr_mask_i(t_b_wr_mask),
        .b_rd_data_o(t_b_rd_data)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic clear_inputs();
        begin
            w_load_en = 1'b0;
            w_load_wr_en = 1'b0;
            w_load_addr = '0;
            w_load_wr_data = '0;
            w_load_wr_mask = '0;
            w_acc_rd_en = 1'b0;
            w_acc_rd_addr = '0;

            ao_rd_en = 1'b0;
            ao_rd_addr = '0;
            ao_wr_en = 1'b0;
            ao_wr_addr = '0;
            ao_wr_data = '0;
            ao_wr_mask = '0;
            ao_aux_en = 1'b0;
            ao_aux_wr_en = 1'b0;
            ao_aux_addr = '0;
            ao_aux_wr_data = '0;
            ao_aux_wr_mask = '0;

            t_a_en = 1'b0;
            t_a_wr_en = 1'b0;
            t_a_addr = '0;
            t_a_wr_data = '0;
            t_a_wr_mask = '0;
            t_b_en = 1'b0;
            t_b_wr_en = 1'b0;
            t_b_addr = '0;
            t_b_wr_data = '0;
            t_b_wr_mask = '0;
        end
    endtask

    task automatic write_weight(input int addr, input logic [DATA_W-1:0] data, input logic [WMASK_W-1:0] mask);
        begin
            @(negedge clk);
            w_load_en = 1'b1;
            w_load_wr_en = 1'b1;
            w_load_addr = addr[ADDR_W-1:0];
            w_load_wr_data = data;
            w_load_wr_mask = mask;
            @(negedge clk);
            w_load_en = 1'b0;
            w_load_wr_en = 1'b0;
        end
    endtask

    task automatic read_weight(input int addr, output logic [DATA_W-1:0] data);
        begin
            @(negedge clk);
            w_acc_rd_en = 1'b1;
            w_acc_rd_addr = addr[ADDR_W-1:0];
            @(posedge clk);
            #1;
            data = w_acc_rd_data;
            @(negedge clk);
            w_acc_rd_en = 1'b0;
        end
    endtask

    task automatic write_ao(input int addr, input logic [DATA_W-1:0] data, input logic [WMASK_W-1:0] mask);
        begin
            @(negedge clk);
            ao_wr_en = 1'b1;
            ao_wr_addr = addr[ADDR_W-1:0];
            ao_wr_data = data;
            ao_wr_mask = mask;
            @(negedge clk);
            ao_wr_en = 1'b0;
        end
    endtask

    task automatic read_ao(input int addr, output logic [DATA_W-1:0] data);
        begin
            @(negedge clk);
            ao_rd_en = 1'b1;
            ao_rd_addr = addr[ADDR_W-1:0];
            @(posedge clk);
            #1;
            data = ao_rd_data;
            @(negedge clk);
            ao_rd_en = 1'b0;
        end
    endtask

    task automatic test_simple_dual_wrappers();
        logic [DATA_W-1:0] read_word;
        logic [DATA_W-1:0] exp_word;
        begin
            write_weight(3, 128'h00112233445566778899aabbccddeeff, '1);
            read_weight(3, read_word);
            check(read_word === 128'h00112233445566778899aabbccddeeff,
                  "weight global buffer full-word readback failed");

            write_weight(3, 128'hffffeeee111122223333444455556666, 16'h0003);
            read_weight(3, read_word);
            exp_word = 128'h00112233445566778899aabbccdd6666;
            check(read_word === exp_word, "weight global buffer byte-mask write failed");

            write_ao(8, 128'h0123456789abcdeffedcba9876543210, '1);
            write_ao(40, 128'h11111111222222223333333344444444, '1);
            read_ao(8, read_word);
            check(read_word === 128'h0123456789abcdeffedcba9876543210,
                  "activation half readback failed");
            read_ao(40, read_word);
            check(read_word === 128'h11111111222222223333333344444444,
                  "output half readback failed");
        end
    endtask

    task automatic test_true_dual_model();
        begin
            @(negedge clk);
            t_a_en = 1'b1;
            t_a_wr_en = 1'b1;
            t_a_addr = 5;
            t_a_wr_data = 128'haaaaaaaaaaaaaaaa5555555555555555;
            t_a_wr_mask = '1;
            t_b_en = 1'b1;
            t_b_wr_en = 1'b1;
            t_b_addr = 6;
            t_b_wr_data = 128'h0123012301230123fedcfedcfedcfedc;
            t_b_wr_mask = '1;

            @(negedge clk);
            t_a_wr_en = 1'b0;
            t_a_addr = 6;
            t_b_wr_en = 1'b0;
            t_b_addr = 5;

            @(posedge clk);
            #1;
            check(t_a_rd_data === 128'h0123012301230123fedcfedcfedcfedc,
                  "true dual port A read failed");
            check(t_b_rd_data === 128'haaaaaaaaaaaaaaaa5555555555555555,
                  "true dual port B read failed");

            @(negedge clk);
            t_a_en = 1'b0;
            t_b_en = 1'b0;
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        clear_inputs();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        test_simple_dual_wrappers();
        test_true_dual_model();

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] global_sram_models FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] global_sram_models PASSED");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
