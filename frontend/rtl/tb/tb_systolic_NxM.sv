`timescale 1ns/1ps

module tb_systolic_NxM;
    parameter int ROW   = 3;
    parameter int COL   = 4;
    parameter int CIN   = 5;
    parameter int INTX  = 8;
    parameter int ACC_W = 32;
    parameter int HALF_CYCLE_TIME = 5;
    parameter int CYCLE_TIME = 10;
    parameter int TIMEOUT_CYCLES = 100;

    localparam int FEED_CYCLES = CIN + ((ROW > COL) ? ROW : COL) - 1;

    logic clk;
    logic rst_n;
    logic en_i;
    logic row_first_i [ROW];
    logic col_first_i [COL];
    logic signed [INTX-1:0]  row_i [ROW];
    logic                    row_valid_i [ROW];
    logic signed [INTX-1:0]  col_i [COL];
    logic                    col_valid_i [COL];
    logic                    valid_o [ROW][COL];
    logic signed [ACC_W-1:0] mac_o [ROW][COL];

    // Input matrices and golden reference from python model.
    logic signed [INTX-1:0]  act_mem [ROW*CIN];
    logic signed [INTX-1:0]  wgt_mem [CIN*COL];
    logic signed [ACC_W-1:0] golden_mac [ROW*COL];

    integer cycle_count;
    integer pass_cnt;
    integer fail_cnt;
    integer x_idx;
    integer y_idx;
    integer k_idx;
    
    initial clk = 1'b0;
    always #HALF_CYCLE_TIME clk = ~clk;

    initial $readmemh("gold_models/activation.hex", act_mem);
    initial $readmemh("gold_models/weight.hex", wgt_mem);
    initial $readmemh("gold_models/golden.hex", golden_mac);

    // implementation of module systolic_array
    systolic_array #(
        .ROW   	(ROW   ),
        .COL   	(COL   ),
        .INTX  	(INTX   ),
        .ACC_W 	(32  ))
    u_systolic_array(
        .clk         	(clk          ),
        .rst_n       	(rst_n        ),
        .en_i        	(en_i         ),
        .row_first_i 	(row_first_i  ),
        .col_first_i 	(col_first_i  ),
        .row_i       	(row_i        ),
        .row_valid_i 	(row_valid_i  ),
        .col_i       	(col_i        ),
        .col_valid_i 	(col_valid_i  ),
        .valid_o     	(valid_o      ),
        .mac_o       	(mac_o        )
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
        end
    end

    task automatic clear_inputs ();
        begin
            for (x_idx = 0; x_idx < ROW; x_idx = x_idx + 1) begin
                row_i[x_idx]       = '0;
                row_valid_i[x_idx] = 1'b0;
                row_first_i[x_idx] = 1'b0;
            end

            for (y_idx = 0; y_idx < COL; y_idx = y_idx + 1) begin
                col_i[y_idx]       = '0;
                col_valid_i[y_idx] = 1'b0;
                col_first_i[y_idx] = 1'b0;
            end
        end
    endtask

    task automatic drive_systolic_inputs ();
        begin
            for (k_idx = 0; k_idx < FEED_CYCLES; k_idx = k_idx + 1) begin
                @(negedge clk);
                clear_inputs();

                for (x_idx = 0; x_idx < ROW; x_idx = x_idx + 1) begin
                    if ((k_idx >= x_idx) && ((k_idx - x_idx) < CIN)) begin
                        row_i[x_idx]       = act_mem[x_idx*CIN + (k_idx - x_idx)];
                        row_valid_i[x_idx] = 1'b1;
                        row_first_i[x_idx] = ((k_idx - x_idx) == 0);
                    end
                end

                for (y_idx = 0; y_idx < COL; y_idx = y_idx + 1) begin
                    if ((k_idx >= y_idx) && ((k_idx - y_idx) < CIN)) begin
                        col_i[y_idx]       = wgt_mem[(k_idx - y_idx)*COL + y_idx];
                        col_valid_i[y_idx] = 1'b1;
                        col_first_i[y_idx] = ((k_idx - y_idx) == 0);
                    end
                end
            end

            @(negedge clk);
            clear_inputs();
        end
    endtask
    
    task automatic compare_results ();
        begin
            pass_cnt = 0;
            fail_cnt = 0;

            for (x_idx = 0; x_idx < ROW; x_idx = x_idx + 1) begin
                for (y_idx = 0; y_idx < COL; y_idx = y_idx + 1) begin
                    if (mac_o[x_idx][y_idx] === golden_mac[x_idx*COL + y_idx]) begin
                        pass_cnt = pass_cnt + 1;
                        $display("[PASS] mac_o[%0d][%0d] = %0d (0x%08h)",
                                 x_idx, y_idx, mac_o[x_idx][y_idx], mac_o[x_idx][y_idx]);
                    end else begin
                        fail_cnt = fail_cnt + 1;
                        $error("[FAIL] mac_o[%0d][%0d] expected %0d (0x%08h), got %0d (0x%08h)",
                               x_idx, y_idx,
                               golden_mac[x_idx*COL + y_idx],
                               golden_mac[x_idx*COL + y_idx],
                               mac_o[x_idx][y_idx],
                               mac_o[x_idx][y_idx]);
                    end
                end
            end

            $display("[TB] compare done: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        en_i  = 1'b0;
        clear_inputs();

        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        en_i  = 1'b1;

        $display("[TB] start systolic_NxM test ROW=%0d COL=%0d CIN=%0d", ROW, COL, CIN);
        drive_systolic_inputs();

        repeat (ROW + COL + CIN) @(posedge clk);
        compare_results();

        if (fail_cnt == 0) begin
            $display("[TB] systolic_NxM PASSED");
            $finish;
        end else begin
            $fatal(1, "[TB] systolic_NxM FAILED");
        end
    end

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] timeout after %0d cycles", TIMEOUT_CYCLES);
    end
    
endmodule
