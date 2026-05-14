`timescale 1ns/1ps

module tb_conv1x1_level3_top;
    parameter int ROW = 4;
    parameter int COL = 4;
    parameter int K_MAX = 16;
    parameter int DATA_W = 8;
    parameter int ACC_W = 32;
    parameter int BIAS_W = 64;
    parameter int OUT_W = 8;
    parameter int MULT_W = 32;
    parameter int SHIFT_W = 6;
    parameter int DIM_W = 16;
    parameter int GB_DATA_W = 32;
    parameter int AO_DEPTH = 128;
    parameter int WGT_DEPTH = 128;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int TIMEOUT_CYCLES = 200000;

    localparam int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX);
    localparam int AO_ADDR_W = (AO_DEPTH <= 1) ? 1 : $clog2(AO_DEPTH);
    localparam int WGT_ADDR_W = (WGT_DEPTH <= 1) ? 1 : $clog2(WGT_DEPTH);
    localparam int GB_ADDR_W = (AO_ADDR_W > WGT_ADDR_W) ? AO_ADDR_W : WGT_ADDR_W;
    localparam int WB_ADDR_W = (ROW <= 1) ? 1 : $clog2(ROW);
    localparam int MASK_W = GB_DATA_W / DATA_W;
    localparam int OUT_BASE = AO_DEPTH / 2;
    localparam int WGT2_BASE = 32;
    localparam int M = 5;
    localparam int K1 = 6;
    localparam int N1 = 4;
    localparam int K2 = N1;
    localparam int N2 = 4;

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic start_i;
    logic busy_o;
    logic done_o;
    logic [K_ADDR_W:0] k_size_i;
    logic [DIM_W-1:0] m_size_i;
    logic [DIM_W-1:0] n_size_i;
    logic [GB_ADDR_W-1:0] act_base_addr_i;
    logic [GB_ADDR_W-1:0] wgt_base_addr_i;
    logic [GB_ADDR_W-1:0] out_base_addr_i;

    logic [1:0] mode_i;
    logic signed [BIAS_W-1:0] bias_i [COL];
    logic signed [MULT_W-1:0] multiplier_i [COL];
    logic [SHIFT_W-1:0] shift_i [COL];
    logic signed [OUT_W-1:0] zero_point_i [COL];
    logic signed [MULT_W-1:0] prelu_multiplier_i [COL];
    logic [SHIFT_W-1:0] prelu_shift_i [COL];
    logic signed [MULT_W-1:0] residual_multiplier_i [COL];
    logic [SHIFT_W-1:0] residual_shift_i [COL];
    logic signed [ACC_W-1:0] residual_zero_point_i [COL];

    logic host_ao_wr_en_i;
    logic [AO_ADDR_W-1:0] host_ao_addr_i;
    logic [GB_DATA_W-1:0] host_ao_wr_data_i;
    logic [MASK_W-1:0] host_ao_wr_mask_i;
    logic host_ao_rd_en_i;
    logic [GB_DATA_W-1:0] host_ao_rd_data_o;

    logic host_wgt_wr_en_i;
    logic [WGT_ADDR_W-1:0] host_wgt_addr_i;
    logic [GB_DATA_W-1:0] host_wgt_wr_data_i;
    logic [MASK_W-1:0] host_wgt_wr_mask_i;

    logic dut_act_rd_valid;
    logic [GB_ADDR_W-1:0] dut_act_rd_addr;
    logic [GB_DATA_W-1:0] dut_act_rd_data;
    logic dut_ao_wr_valid;
    logic [GB_ADDR_W-1:0] dut_ao_wr_addr;
    logic [GB_DATA_W-1:0] dut_ao_wr_data;
    logic [MASK_W-1:0] dut_ao_wr_mask;
    logic dut_wgt_rd_valid;
    logic [GB_ADDR_W-1:0] dut_wgt_rd_addr;
    logic [GB_DATA_W-1:0] dut_wgt_rd_data;

    logic                       conv_post_valid_tile;
    logic                       post_valid_tile;
    logic [DIM_W-1:0]           conv_post_row_base;
    logic [DIM_W-1:0]           conv_post_col_base;
    logic [DIM_W-1:0]           conv_post_m_size;
    logic [DIM_W-1:0]           conv_post_n_size;
    logic [1:0]                 conv_post_mode;
    logic                       conv_post_valid [ROW][COL];
    logic signed [ACC_W-1:0]    conv_post_acc [ROW][COL];
    logic signed [ACC_W-1:0]    conv_post_residual [ROW][COL];
    logic signed [BIAS_W-1:0]   conv_post_bias [COL];
    logic signed [MULT_W-1:0]   conv_post_multiplier [COL];
    logic [SHIFT_W-1:0]         conv_post_shift [COL];
    logic signed [OUT_W-1:0]    conv_post_zero_point [COL];
    logic signed [MULT_W-1:0]   conv_post_prelu_multiplier [COL];
    logic [SHIFT_W-1:0]         conv_post_prelu_shift [COL];
    logic signed [MULT_W-1:0]   conv_post_residual_multiplier [COL];
    logic [SHIFT_W-1:0]         conv_post_residual_shift [COL];
    logic signed [ACC_W-1:0]    conv_post_residual_zero_point [COL];
    logic                       conv_wb_capture_en;
    logic                       conv_wb_done;
    logic [DIM_W-1:0]           conv_wb_m_size;
    logic [DIM_W-1:0]           conv_wb_n_size;
    logic [GB_ADDR_W-1:0]       conv_wb_out_base_addr;
    logic                       post_valid [ROW][COL];
    logic signed [OUT_W-1:0]    post_data [ROW][COL];
    logic [WB_ADDR_W-1:0]       conv_wb_rd_addr;
    logic [GB_DATA_W-1:0]       conv_wb_data;

    logic ao_rd_en;
    logic [AO_ADDR_W-1:0] ao_rd_addr;
    logic [GB_DATA_W-1:0] ao_rd_data;
    logic ao_wr_en;
    logic [AO_ADDR_W-1:0] ao_wr_addr;
    logic [GB_DATA_W-1:0] ao_wr_data;
    logic [MASK_W-1:0] ao_wr_mask;

    logic [GB_DATA_W-1:0] ao_init [AO_DEPTH];
    logic [GB_DATA_W-1:0] wgt_init [WGT_DEPTH];
    logic [GB_DATA_W-1:0] golden [AO_DEPTH];
    int fail_cnt;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    activation_output_global_buffer #(
        .DATA_W(GB_DATA_W),
        .DEPTH(AO_DEPTH),
        .BYTE_W(DATA_W),
        .TRUE_DUAL_PORT(1'b0),
        .ADDR_W(AO_ADDR_W)
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
        .aux_en_i(1'b0),
        .aux_wr_en_i(1'b0),
        .aux_addr_i('0),
        .aux_wr_data_i('0),
        .aux_wr_mask_i('0),
        .aux_rd_data_o()
    );

    weight_global_buffer #(
        .DATA_W(GB_DATA_W),
        .DEPTH(WGT_DEPTH),
        .BYTE_W(DATA_W),
        .TRUE_DUAL_PORT(1'b0),
        .ADDR_W(WGT_ADDR_W)
    ) u_wgt_gb (
        .clk(clk),
        .rst_n(rst_n),
        .load_en_i(host_wgt_wr_en_i && !busy_o),
        .load_wr_en_i(host_wgt_wr_en_i && !busy_o),
        .load_addr_i(host_wgt_addr_i),
        .load_wr_data_i(host_wgt_wr_data_i),
        .load_wr_mask_i(host_wgt_wr_mask_i),
        .load_rd_data_o(),
        .acc_rd_en_i(dut_wgt_rd_valid),
        .acc_rd_addr_i(dut_wgt_rd_addr[WGT_ADDR_W-1:0]),
        .acc_rd_data_o(dut_wgt_rd_data)
    );

    assign ao_rd_en = busy_o ? dut_act_rd_valid : host_ao_rd_en_i;
    assign ao_rd_addr = busy_o ? dut_act_rd_addr[AO_ADDR_W-1:0] : host_ao_addr_i;
    assign dut_act_rd_data = ao_rd_data;
    assign host_ao_rd_data_o = ao_rd_data;

    assign ao_wr_en = busy_o ? dut_ao_wr_valid : host_ao_wr_en_i;
    assign ao_wr_addr = busy_o ? dut_ao_wr_addr[AO_ADDR_W-1:0] : host_ao_addr_i;
    assign ao_wr_data = busy_o ? dut_ao_wr_data : host_ao_wr_data_i;
    assign ao_wr_mask = busy_o ? dut_ao_wr_mask : host_ao_wr_mask_i;

    conv1x1_level3_top #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W),
        .GB_DATA_W(GB_DATA_W),
        .AO_DEPTH(AO_DEPTH),
        .WGT_DEPTH(WGT_DEPTH)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .layer_idx_i('0),
        .busy_o(busy_o),
        .done_o(done_o),
        .k_size_i(k_size_i),
        .m_size_i(m_size_i),
        .n_size_i(n_size_i),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .out_base_addr_i(out_base_addr_i),
        .residual_en_i(1'b0),
        .residual_base_addr_i('0),
        .mode_i(mode_i),
        .bias_i(bias_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .zero_point_i(zero_point_i),
        .prelu_multiplier_i(prelu_multiplier_i),
        .prelu_shift_i(prelu_shift_i),
        .residual_multiplier_i(residual_multiplier_i),
        .residual_shift_i(residual_shift_i),
        .residual_zero_point_i(residual_zero_point_i),
        .post_valid_tile_o(conv_post_valid_tile),
        .post_valid_tile_i(post_valid_tile),
        .post_row_base_o(conv_post_row_base),
        .post_col_base_o(conv_post_col_base),
        .post_m_size_o(conv_post_m_size),
        .post_n_size_o(conv_post_n_size),
        .post_mode_o(conv_post_mode),
        .post_valid_o(conv_post_valid),
        .post_acc_o(conv_post_acc),
        .post_residual_o(conv_post_residual),
        .post_bias_o(conv_post_bias),
        .post_multiplier_o(conv_post_multiplier),
        .post_shift_o(conv_post_shift),
        .post_zero_point_o(conv_post_zero_point),
        .post_prelu_multiplier_o(conv_post_prelu_multiplier),
        .post_prelu_shift_o(conv_post_prelu_shift),
        .post_residual_multiplier_o(conv_post_residual_multiplier),
        .post_residual_shift_o(conv_post_residual_shift),
        .post_residual_zero_point_o(conv_post_residual_zero_point),
        .wb_capture_en_o(conv_wb_capture_en),
        .wb_done_i(conv_wb_done),
        .wb_m_size_o(conv_wb_m_size),
        .wb_n_size_o(conv_wb_n_size),
        .wb_out_base_addr_o(conv_wb_out_base_addr),
        .gb_act_rd_valid_o(dut_act_rd_valid),
        .gb_act_rd_addr_o(dut_act_rd_addr),
        .gb_act_rd_data_i(dut_act_rd_data),
        .gb_wgt_rd_valid_o(dut_wgt_rd_valid),
        .gb_wgt_rd_addr_o(dut_wgt_rd_addr),
        .gb_wgt_rd_data_i(dut_wgt_rd_data)
    );

    conv1x1_output_postprocess #(
        .ROW(ROW),
        .COL(COL),
        .ACC_W(ACC_W),
        .BIAS_W(BIAS_W),
        .OUT_W(OUT_W),
        .MULT_W(MULT_W),
        .SHIFT_W(SHIFT_W),
        .DIM_W(DIM_W)
    ) u_postprocess (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .valid_tile_i(conv_post_valid_tile),
        .row_base_i(conv_post_row_base),
        .col_base_i(conv_post_col_base),
        .m_size_i(conv_post_m_size),
        .n_size_i(conv_post_n_size),
        .valid_i(conv_post_valid),
        .acc_i(conv_post_acc),
        .mode_i(conv_post_mode),
        .bias_i(conv_post_bias),
        .multiplier_i(conv_post_multiplier),
        .shift_i(conv_post_shift),
        .zero_point_i(conv_post_zero_point),
        .prelu_multiplier_i(conv_post_prelu_multiplier),
        .prelu_shift_i(conv_post_prelu_shift),
        .residual_i(conv_post_residual),
        .residual_multiplier_i(conv_post_residual_multiplier),
        .residual_shift_i(conv_post_residual_shift),
        .residual_zero_point_i(conv_post_residual_zero_point),
        .valid_o(post_valid),
        .valid_tile_o(post_valid_tile),
        .data_o(post_data)
    );

    wb_buffer #(
        .ROW(ROW),
        .COL(COL),
        .DATA_IN_W(OUT_W),
        .DATA_OUT_W(GB_DATA_W)
    ) u_wb_buffer (
        .aclk(clk),
        .aresetn(rst_n),
        .wr_en_i(conv_wb_capture_en),
        .data_i(post_data),
        .rd_addr_i(conv_wb_rd_addr),
        .data_o(conv_wb_data)
    );

    wr_controller #(
        .ROW(ROW),
        .COL(COL),
        .DATA_OUT_W(GB_DATA_W),
        .DIM_W(DIM_W),
        .GB_ADDR_W(GB_ADDR_W)
    ) u_wr_controller (
        .aclk(clk),
        .aresetn(rst_n),
        .n_size_i(conv_wb_n_size),
        .m_size_i(conv_wb_m_size),
        .out_base_addr_i(conv_wb_out_base_addr),
        .tile_process_done(conv_wb_capture_en),
        .data_i(conv_wb_data),
        .rd_addr_o(conv_wb_rd_addr),
        .ao_addr_o(dut_ao_wr_addr),
        .ao_wr_en_o(dut_ao_wr_valid),
        .ao_data_o(dut_ao_wr_data),
        .busy_o(),
        .done_o(conv_wb_done)
    );

    assign dut_ao_wr_mask = {MASK_W{1'b1}};

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic host_write_ao(input int addr, input logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_ao_wr_en_i = 1'b1;
            host_ao_addr_i = addr[AO_ADDR_W-1:0];
            host_ao_wr_data_i = data;
            host_ao_wr_mask_i = '1;
            @(negedge clk);
            host_ao_wr_en_i = 1'b0;
        end
    endtask

    task automatic host_write_wgt(input int addr, input logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_wgt_wr_en_i = 1'b1;
            host_wgt_addr_i = addr[WGT_ADDR_W-1:0];
            host_wgt_wr_data_i = data;
            host_wgt_wr_mask_i = '1;
            @(negedge clk);
            host_wgt_wr_en_i = 1'b0;
        end
    endtask

    task automatic host_read_ao(input int addr, output logic [GB_DATA_W-1:0] data);
        begin
            @(negedge clk);
            host_ao_rd_en_i = 1'b1;
            host_ao_addr_i = addr[AO_ADDR_W-1:0];
            @(posedge clk);
            #1;
            data = host_ao_rd_data_o;
            @(negedge clk);
            host_ao_rd_en_i = 1'b0;
        end
    endtask

    task automatic pulse_start_and_wait();
        begin
            @(negedge clk);
            start_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start_i = 1'b0;
            wait (done_o === 1'b1);
            @(posedge clk);
        end
    endtask

    task automatic run_layer(input int k_size, input int n_size, input int act_base, input int wgt_base, input int out_base);
        begin
            k_size_i = k_size[K_ADDR_W:0];
            m_size_i = M[DIM_W-1:0];
            n_size_i = n_size[DIM_W-1:0];
            act_base_addr_i = act_base[AO_ADDR_W-1:0];
            wgt_base_addr_i = wgt_base[WGT_ADDR_W-1:0];
            out_base_addr_i = out_base[AO_ADDR_W-1:0];
            pulse_start_and_wait();
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic load_memories();
        begin
            $readmemh("gold_models/conv1x1_level3_ao_init.hex", ao_init);
            $readmemh("gold_models/conv1x1_level3_wgt_init.hex", wgt_init);
            $readmemh("gold_models/conv1x1_level3_golden.hex", golden);

            for (int i = 0; i < AO_DEPTH; i++) begin
                host_write_ao(i, ao_init[i]);
            end
            for (int i = 0; i < WGT_DEPTH; i++) begin
                host_write_wgt(i, wgt_init[i]);
            end
        end
    endtask

    task automatic compare_final();
        logic [GB_DATA_W-1:0] got;
        int n_tiles;
        int addr;
        begin
            n_tiles = (N2 + COL - 1) / COL;
            for (int r = 0; r < M; r++) begin
                for (int nt = 0; nt < n_tiles; nt++) begin
                    addr = OUT_BASE + r*n_tiles + nt;
                    host_read_ao(addr, got);
                    check(got === golden[addr],
                          $sformatf("final addr=%0d expected=0x%08h got=0x%08h",
                                    addr, golden[addr], got));
                end
            end
        end
    endtask

    task automatic dump_ao_sram(input string path);
        int fd;
        logic [GB_DATA_W-1:0] got;
        begin
            fd = $fopen(path, "w");
            check(fd != 0, $sformatf("failed to open %s", path));
            if (fd != 0) begin
                for (int addr = 0; addr < AO_DEPTH; addr++) begin
                    host_read_ao(addr, got);
                    $fdisplay(fd, "%08h", got);
                end
                $fclose(fd);
            end
        end
    endtask

    initial begin
        fail_cnt = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        start_i = 1'b0;
        mode_i = 2'd0;
        k_size_i = '0;
        m_size_i = '0;
        n_size_i = '0;
        act_base_addr_i = '0;
        wgt_base_addr_i = '0;
        out_base_addr_i = '0;
        host_ao_wr_en_i = 1'b0;
        host_ao_addr_i = '0;
        host_ao_wr_data_i = '0;
        host_ao_wr_mask_i = '0;
        host_ao_rd_en_i = 1'b0;
        host_wgt_wr_en_i = 1'b0;
        host_wgt_addr_i = '0;
        host_wgt_wr_data_i = '0;
        host_wgt_wr_mask_i = '0;

        for (int c = 0; c < COL; c++) begin
            bias_i[c] = '0;
            multiplier_i[c] = 1;
            shift_i[c] = '0;
            zero_point_i[c] = '0;
            prelu_multiplier_i[c] = 1;
            prelu_shift_i[c] = '0;
            residual_multiplier_i[c] = '0;
            residual_shift_i[c] = '0;
            residual_zero_point_i[c] = '0;
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        load_memories();
        run_layer(K1, N1, 0, 0, OUT_BASE);
        run_layer(K2, N2, OUT_BASE, WGT2_BASE, OUT_BASE);
        dump_ao_sram("gold_models/conv1x1_level3_dut_ao_final.hex");
        compare_final();

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] conv1x1_level3_top FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] conv1x1_level3_top PASSED");
        $finish;
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
endmodule
