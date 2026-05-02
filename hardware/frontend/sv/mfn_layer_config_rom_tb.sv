module mfn_layer_config_rom_tb;

    logic clk;
    logic [5:0] addr;
    logic [9:0] out_in_ch, out_out_ch;
    logic [7:0] out_width, out_height;
    logic [1:0] out_stride;
    logic out_has_prelu, out_ping_pong_flag;

    mfn_layer_config_rom #(6) dut (.*);

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $display("Testing mfn_layer_config_rom");
        addr = 0;
        #20;
        addr = 1;
        #10;
        addr = 57;
        #20 $finish;
    end
    
    initial begin
        $monitor("Time=%0t | addr=%d | in=%d out=%d w=%d h=%d str=%d prelu=%b pp=%b", 
                 $time, addr, out_in_ch, out_out_ch, out_width, out_height, out_stride, out_has_prelu, out_ping_pong_flag);
    end

endmodule
