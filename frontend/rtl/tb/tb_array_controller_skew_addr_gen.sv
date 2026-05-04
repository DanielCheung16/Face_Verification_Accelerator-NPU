`timescale 1ns/1ps

module tb_array_controller_skew_addr_gen;
    localparam int ROW      = 3;
    localparam int COL      = 4;
    localparam int K_MAX    = 8;
    localparam int COUNT_W  = 8;
    localparam int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX);
    localparam int MAX_ROW_COL = (ROW >= COL) ? ROW : COL;

    logic clk;
    logic rst_n;
    logic start_i;
    logic run_en_i;
    logic [K_ADDR_W:0] k_size_i;

    logic [COUNT_W-1:0] feed_cycle_o;
    logic feed_valid_o;
    logic array_en_o;
    logic busy_o;
    logic done_o;

    logic [K_ADDR_W-1:0] act_rd_idx_o   [ROW];
    logic                act_rd_valid_o [ROW];
    logic                act_first_o    [ROW];
    logic [K_ADDR_W-1:0] wgt_rd_idx_o   [COL];
    logic                wgt_rd_valid_o [COL];
    logic                wgt_first_o    [COL];

    array_controller #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .COUNT_W(COUNT_W),
        .K_ADDR_W(K_ADDR_W)
    ) u_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .start_i(start_i),
        .run_en_i(run_en_i),
        .k_size_i(k_size_i),
        .feed_cycle_o(feed_cycle_o),
        .feed_valid_o(feed_valid_o),
        .array_en_o(array_en_o),
        .busy_o(busy_o),
        .done_o(done_o)
    );

    skew_addr_gen #(
        .ROW(ROW),
        .COL(COL),
        .K_MAX(K_MAX),
        .COUNT_W(COUNT_W),
        .K_ADDR_W(K_ADDR_W)
    ) u_skew (
        .k_size_i(k_size_i),
        .feed_cycle_i(feed_cycle_o),
        .feed_valid_i(feed_valid_o),
        .act_rd_idx_o(act_rd_idx_o),
        .act_rd_valid_o(act_rd_valid_o),
        .act_first_o(act_first_o),
        .wgt_rd_idx_o(wgt_rd_idx_o),
        .wgt_rd_valid_o(wgt_rd_valid_o),
        .wgt_first_o(wgt_first_o)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic check(bit cond, string msg);
        if (!cond) begin
            $error("%s", msg);
            $finish;
        end
    endtask

    task automatic check_skew(input int cycle, input bit feed_valid);
        bit exp_valid;
        int exp_idx;

        for (int r = 0; r < ROW; r++) begin
            exp_valid = feed_valid && (cycle >= r) && ((cycle - r) < k_size_i);
            exp_idx   = exp_valid ? (cycle - r) : 0;

            check(act_rd_valid_o[r] == exp_valid, $sformatf("act valid row %0d cycle %0d", r, cycle));
            check(act_rd_idx_o[r] == exp_idx[K_ADDR_W-1:0], $sformatf("act idx row %0d cycle %0d", r, cycle));
            check(act_first_o[r] == (exp_valid && (exp_idx == 0)), $sformatf("act first row %0d cycle %0d", r, cycle));
        end

        for (int c = 0; c < COL; c++) begin
            exp_valid = feed_valid && (cycle >= c) && ((cycle - c) < k_size_i);
            exp_idx   = exp_valid ? (cycle - c) : 0;

            check(wgt_rd_valid_o[c] == exp_valid, $sformatf("wgt valid col %0d cycle %0d", c, cycle));
            check(wgt_rd_idx_o[c] == exp_idx[K_ADDR_W-1:0], $sformatf("wgt idx col %0d cycle %0d", c, cycle));
            check(wgt_first_o[c] == (exp_valid && (exp_idx == 0)), $sformatf("wgt first col %0d cycle %0d", c, cycle));
        end
    endtask

    initial begin
        int k_size;
        int feed_last;
        int drain_last;

        rst_n    = 1'b0;
        start_i  = 1'b0;
        run_en_i = 1'b1;
        k_size_i = '0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        check(!busy_o && !done_o && !array_en_o && !feed_valid_o, "controller should idle after reset");
        check_skew(0, 1'b0);

        k_size     = 3;
        k_size_i   = k_size[K_ADDR_W:0];
        feed_last  = k_size + MAX_ROW_COL - 2;
        drain_last = k_size + ROW + COL - 2;

        start_i = 1'b1;
        @(posedge clk);
        start_i = 1'b0;
        #1;

        for (int cycle = 0; cycle <= feed_last; cycle++) begin
            check(feed_cycle_o == cycle[COUNT_W-1:0], $sformatf("feed_cycle_o should be %0d", cycle));
            check(feed_valid_o, $sformatf("feed_valid_o should assert during feed cycle %0d", cycle));
            check(array_en_o && busy_o && !done_o, $sformatf("array should run during feed cycle %0d", cycle));
            check_skew(cycle, 1'b1);
            @(posedge clk);
            #1;
        end

        for (int cycle = feed_last + 1; cycle <= drain_last; cycle++) begin
            check(feed_cycle_o == cycle[COUNT_W-1:0], $sformatf("feed_cycle_o should continue through drain cycle %0d", cycle));
            check(!feed_valid_o, $sformatf("feed_valid_o should deassert during drain cycle %0d", cycle));
            check(array_en_o && busy_o && !done_o, $sformatf("array should drain during cycle %0d", cycle));
            check_skew(cycle, 1'b0);
            @(posedge clk);
            #1;
        end

        check(done_o && !busy_o && !array_en_o && !feed_valid_o, "done_o should pulse after drain");
        check(feed_cycle_o == '0, "feed_cycle_o should clear when done");
        check_skew(0, 1'b0);

        @(posedge clk);
        #1;
        check(!busy_o && !done_o && !array_en_o && !feed_valid_o, "controller should return to idle after done pulse");

        $display("tb_array_controller_skew_addr_gen PASS");
        $finish;
    end
endmodule
