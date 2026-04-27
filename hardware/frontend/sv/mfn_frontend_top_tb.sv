// ==============================================================================
// Module: mfn_frontend_top_tb
// Description: Integration testbench for MobileFaceNet Frontend.
//              Runs Layer 0 (Conv1) + Layer 1 (DW-Conv1) with verification.
// ==============================================================================

module mfn_frontend_top_tb;

    parameter int DWIDTH = 16;
    parameter int AWIDTH = 40;
    parameter int M_ADDR_WIDTH = 18;

    logic clk;
    logic rst_n;
    logic start_inference;
    logic inference_done;
    
    logic valid_in;
    logic signed [DWIDTH-1:0] pixel_in;
    
    logic valid_out;
    logic signed [DWIDTH-1:0] pixel_out;
    
    logic [M_ADDR_WIDTH-1:0] sram_rd_addr;
    logic [M_ADDR_WIDTH-1:0] sram_wr_addr;

    // SRAM Model
    logic signed [DWIDTH-1:0] sram_mem [0:(1<<M_ADDR_WIDTH)-1];

    // DUT
    mfn_frontend_top #(
        .DWIDTH(DWIDTH),
        .AWIDTH(AWIDTH),
        .M_ADDR_WIDTH(M_ADDR_WIDTH)
    ) dut (.*);

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // SRAM Write Monitoring
    integer l1_write_count = 0;
    always @(posedge clk) begin
        if (valid_out) begin
            sram_mem[sram_wr_addr] <= pixel_out;
            if (sram_wr_addr == 18'h10000) begin
                $display("CRITICAL: Write to 0x10000 at time=%0t | Layer=%0d | Pixel=%d | pp=%b",
                         $time, dut.u_ctrl.layer_idx_reg, pixel_out, dut.u_addr_gen.ping_pong);
            end
            if (sram_wr_addr[11:0] < 2) 
                $display("Time=%0t | Layer=%0d | Addr=%d | Pixel=%d | pp=%b", 
                         $time, dut.u_ctrl.layer_idx_reg, sram_wr_addr, pixel_out,
                         dut.u_addr_gen.ping_pong);
            if (dut.u_ctrl.layer_idx_reg == 1 && l1_write_count < 5) begin
                $display("  [L1 DEBUG] wr_addr=%d raw=%d wr_base=%d wr_ptr=%d pp=%b",
                         sram_wr_addr, dut.u_addr_gen.sram_wr_addr, 
                         dut.u_addr_gen.wr_base, dut.u_addr_gen.wr_ptr_reg,
                         dut.u_addr_gen.ping_pong);
                l1_write_count = l1_write_count + 1;
            end
        end
    end

    // Monitor layer transitions
    initial begin
        @(posedge rst_n);
        forever begin
            @(dut.u_ctrl.state_reg);
            if (dut.u_ctrl.state_reg == dut.u_ctrl.STATE_NEXT_LAYER) begin 
                $display(">>> Time=%0t | LAYER CHANGE: Finished Layer %d", $time, dut.u_ctrl.layer_idx);
                $display("    Saving intermediate results to rtl_out.hex...");
                $writememh("rtl_out.hex", sram_mem);
                
                // Stop after Layer 1 (DW-Conv)
                if (dut.u_ctrl.layer_idx == 1) begin
                    $display("========================================");
                    $display("DEBUG: Stopping after Layer 1 (DW-Conv)");
                    $display("========================================");
                    #100;
                    $finish;
                end
            end
        end
    end

    // --- Cycle Counter ---
    integer cycle_count;
    logic   counting;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            counting    <= 1'b0;
        end else begin
            if (start_inference)
                counting <= 1'b1;
            if (inference_done)
                counting <= 1'b0;
            if (counting)
                cycle_count <= cycle_count + 1;
        end
    end

    // Test Sequence
    initial begin
        rst_n = 0;
        start_inference = 0;
        
        for (int i=0; i<(1<<M_ADDR_WIDTH); i++) sram_mem[i] = '0;
        $readmemh("input.hex", sram_mem);

        $display("Starting MobileFaceNet Layer 0 + Layer 1 Test...");
        
        #50 rst_n = 1;
        #50 start_inference = 1;
        #10 start_inference = 0;
        
        wait(inference_done);
        $display("========================================");
        $display("Success: Inference Done at %0t", $time);
        $display("Total Cycles: %0d", cycle_count);
        $display("========================================");
        
        $writememh("rtl_out.hex", sram_mem);
        #100;
        $finish;
    end

    // SRAM Read Response
    always_ff @(posedge clk) begin
        pixel_in <= sram_mem[sram_rd_addr];
        valid_in <= 1'b1; 
    end

endmodule
