`timescale 1ns/1ps

module tb_spatial_inside_controller;
    parameter int ADDR_W = 16;
    parameter int FILTER_CNT_W = 10;
    parameter int LANES = 16;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int LOAD_LAT = 4;
    parameter int READ_LAT = 6;

    localparam int IFMAP_SIZE = 7;
    localparam int NUM_FILTER = 32;
    localparam int TOTAL_TILES = IFMAP_SIZE * IFMAP_SIZE * (NUM_FILTER / LANES);

    logic clk;
    logic rst_n;
    logic run_en_i;
    logic start_i;
    logic busy_o;
    logic done_o;
    logic [FILTER_CNT_W-1:0] current_num_filter_i;
    logic [2:0] ifmap_size_code_i;
    logic stride_i;
    logic load_busy_i;
    logic load_done_i;
    logic read_busy_i;
    logic read_done_i;
    logic clear_o;
    logic swap_o;
    logic [ADDR_W-1:0] tile_offset_o;
    logic [ADDR_W-1:0] out_x_o;
    logic [ADDR_W-1:0] out_y_o;
    logic load_start_o;
    logic read_start_o;

    int fail_cnt;
    int load_cnt;
    int read_cnt;
    int load_start_count;
    int read_start_count;
    int swap_count;
    int done_count;
    int exp_tile;
    int exp_x;
    int exp_y;
    int load_timer;
    int read_timer;

    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    spatial_inside_controller #(
        .ADDR_W(ADDR_W),
        .FILTER_CNT_W(FILTER_CNT_W),
        .LANES(LANES)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .current_num_filter_i(current_num_filter_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .load_busy_i(load_busy_i),
        .load_done_i(load_done_i),
        .read_busy_i(read_busy_i),
        .read_done_i(read_done_i),
        .clear_o(clear_o),
        .swap_o(swap_o),
        .tile_offset_o(tile_offset_o),
        .out_x_o(out_x_o),
        .out_y_o(out_y_o),
        .load_start_o(load_start_o),
        .read_start_o(read_start_o)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_cnt++;
            $error("%s", msg);
        end
    endtask

    task automatic advance_expected_coord();
        begin
            if (exp_tile + LANES < NUM_FILTER) begin
                exp_tile += LANES;
            end else begin
                exp_tile = 0;
                if (exp_y + 1 < IFMAP_SIZE) begin
                    exp_y += 1;
                end else begin
                    exp_y = 0;
                    if (exp_x + 1 < IFMAP_SIZE) begin
                        exp_x += 1;
                    end else begin
                        exp_x = 0;
                    end
                end
            end
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_timer <= 0;
            read_timer <= 0;
            load_done_i <= 1'b0;
            read_done_i <= 1'b0;
            load_busy_i <= 1'b0;
            read_busy_i <= 1'b0;
        end else begin
            load_done_i <= 1'b0;
            read_done_i <= 1'b0;

            if (load_timer > 0) begin
                if (load_timer == 1) begin
                    load_done_i <= 1'b1;
                    load_busy_i <= 1'b0;
                end
                load_timer <= load_timer - 1;
            end
            if (read_timer > 0) begin
                if (read_timer == 1) begin
                    read_done_i <= 1'b1;
                    read_busy_i <= 1'b0;
                end
                read_timer <= read_timer - 1;
            end

            if (load_start_o) begin
                check(load_timer == 0, "new load_start_o while previous load is busy");
                load_timer <= LOAD_LAT;
                load_busy_i <= 1'b1;
            end
            if (read_start_o) begin
                check(read_timer == 0, "new read_start_o while previous read is busy");
                read_timer <= READ_LAT;
                read_busy_i <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (load_start_o) begin
                check(tile_offset_o == ADDR_W'(exp_tile),
                      $sformatf("load tile_offset expected=%0d got=%0d", exp_tile, tile_offset_o));
                check(out_x_o == ADDR_W'(exp_x),
                      $sformatf("load out_x expected=%0d got=%0d", exp_x, out_x_o));
                check(out_y_o == ADDR_W'(exp_y),
                      $sformatf("load out_y expected=%0d got=%0d", exp_y, out_y_o));
                load_start_count++;
                advance_expected_coord();
            end
            if (read_start_o) begin
                read_start_count++;
            end
            if (swap_o) begin
                swap_count++;
            end
            if (done_o) begin
                done_count++;
            end
        end
    end

    initial begin
        fail_cnt = 0;
        load_cnt = 0;
        read_cnt = 0;
        load_start_count = 0;
        read_start_count = 0;
        swap_count = 0;
        done_count = 0;
        exp_tile = 0;
        exp_x = 0;
        exp_y = 0;
        rst_n = 1'b0;
        run_en_i = 1'b1;
        start_i = 1'b0;
        current_num_filter_i = FILTER_CNT_W'(NUM_FILTER);
        ifmap_size_code_i = 3'd0;
        stride_i = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;

        wait (done_o === 1'b1);
        @(posedge clk);
        #1;

        check(load_start_count == TOTAL_TILES,
              $sformatf("load_start_count expected=%0d got=%0d", TOTAL_TILES, load_start_count));
        check(read_start_count == TOTAL_TILES,
              $sformatf("read_start_count expected=%0d got=%0d", TOTAL_TILES, read_start_count));
        check(swap_count == TOTAL_TILES,
              $sformatf("swap_count expected=%0d got=%0d", TOTAL_TILES, swap_count));
        check(done_count == 1,
              $sformatf("done_count expected=1 got=%0d", done_count));

        if (fail_cnt != 0) begin
            $fatal(1, "[TB] spatial_inside_controller FAILED fail=%0d", fail_cnt);
        end
        $display("[TB] spatial_inside_controller PASSED");
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "[TB] timeout");
    end
endmodule
