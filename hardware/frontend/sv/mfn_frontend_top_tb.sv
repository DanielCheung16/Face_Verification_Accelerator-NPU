// ==============================================================================
// Module: mfn_frontend_top_tb
// Description: Integration testbench for MobileFaceNet Frontend.
//              Simulates the full pipeline with SRAM memory model.
// ==============================================================================

module mfn_frontend_top_tb;

    parameter int DWIDTH = 16;
    parameter int AWIDTH = 32;
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

    // SRAM Model (Simulating SRAM A and B using a single large memory for simplicity)
    logic signed [DWIDTH-1:0] sram_mem [0:(1<<M_ADDR_WIDTH)-1];

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

    // Test Sequence
    initial begin
        // Reset
        rst_n = 0;
        start_inference = 0;
        
        // Note: pixel_in and valid_in are driven by the always_ff block below.
        
        // Initialize memory with zeros
        for (int i=0; i<(1<<M_ADDR_WIDTH); i++) sram_mem[i] = '0;
        
        // Load Input Image Data
        $readmemh("input.hex", sram_mem);

        $display("Starting MobileFaceNet Integration Test...");
        
        #50 rst_n = 1;
        #50 start_inference = 1;
        #10 start_inference = 0;
        
        // Watchdog
        wait(inference_done);
        $display("Success: Inference Done triggered at %0t", $time);
        
        // Dump SRAM results for Bit-True verification
        $writememh("rtl_out.hex", sram_mem);
        
        #100;
        $finish;
    end

    // SRAM Read Response (1 cycle latency simulated)
    always_ff @(posedge clk) begin
        pixel_in <= sram_mem[sram_rd_addr];
        valid_in <= 1'b1; 
    end

    // SRAM Write Logic
    always_ff @(posedge clk) begin
        if (valid_out) begin
            sram_mem[sram_wr_addr] <= pixel_out;
            // Optionally log some writes
            if (sram_wr_addr < 10) 
                $display("Time=%0t | Output Pixel[%d] = %d", $time, sram_wr_addr, pixel_out);
        end
    end

endmodule
