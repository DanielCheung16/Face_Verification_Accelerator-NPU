module mfn_weight_rom_tb;

    logic clk;
    logic [9:0] addr;
    logic signed [15:0] wgt_out [0:8];
    logic signed [31:0] bias_out;
    logic signed [15:0] prelu_weight_out;

    mfn_weight_rom #(10, 16, 32) dut (.*);

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $display("Testing mfn_weight_rom");
        addr = 0;
        #20;
        addr = 1;
        #10;
        addr = 2;
        #20 $finish;
    end
    
    initial begin
        $monitor("Time=%0t | addr=%d | w0=%h w8=%h bias=%h prelu=%h", 
                 $time, addr, wgt_out[0], wgt_out[8], bias_out, prelu_weight_out);
    end

endmodule
