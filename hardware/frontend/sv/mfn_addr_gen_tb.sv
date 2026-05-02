module mfn_addr_gen_tb;

    logic clk;
    logic rst_n;
    logic reset_ptr;
    logic inc_read;
    logic inc_write;
    logic [7:0] img_width;
    logic [7:0] img_height;
    
    logic [17:0] sram_rd_addr;
    logic [17:0] sram_wr_addr;
    logic is_pad;

    mfn_addr_gen #(18) dut (.*);

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 0;
        reset_ptr = 0;
        inc_read = 0;
        inc_write = 0;
        img_width = 8'd4;
        img_height = 8'd4;
        
        #20 rst_n = 1;
        
        #10 reset_ptr = 1;
        #10 reset_ptr = 0;
        
        $display("Testing mfn_addr_gen padding logic (4x4 image -> 6x6 virtual window)");
        $display("Time | inc_read | rd_addr | is_pad");
        // Test reading through a 4x4 image with padding (virtual 6x6)
        // We should see is_pad go high around the edges
        for (int i=0; i<36; i++) begin
            inc_read = 1;
            #10;
        end
        inc_read = 0;
        
        #50 $finish;
    end
    
    initial begin
        $monitor("%0t |    %b     |   %d   |   %b", 
                 $time, inc_read, sram_rd_addr, is_pad);
    end

endmodule
