// ==============================================================================
// Module: mfn_layer_config_rom
// Description: Configuration ROM storing parameters for each layer.
//              Contains 58 layers for MobileFaceNet.
// ==============================================================================

module mfn_layer_config_rom #(
    parameter int ADDR_WIDTH = 6 // 64 entries (sufficient for 58 layers)
)(
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] addr,
    
    // Unpacked Layer Parameters
    output logic [9:0] out_in_ch,
    output logic [9:0] out_out_ch,
    output logic [7:0] out_width,
    output logic [7:0] out_height,
    output logic [1:0] out_stride,
    output logic       out_has_prelu,
    output logic       out_ping_pong_flag
);

    // 10 + 10 + 8 + 8 + 2 + 1 + 1 = 40 bits.
    localparam int ROM_WIDTH = 40;
    
    logic [ROM_WIDTH-1:0] rom_data [0:(1<<ADDR_WIDTH)-1];
    logic [ROM_WIDTH-1:0] read_data;

    // Initialization
    initial begin
        // Example format: {ping_pong(1), has_prelu(1), stride(2), height(8), width(8), out_ch(10), in_ch(10)}
        // Here we just initialize to 0. You can populate with actual config via $readmemb/$readmemh
        for (int i = 0; i < (1<<ADDR_WIDTH); i++) begin
            rom_data[i] = '0;
        end
        $readmemh("config.hex", rom_data);
    end

    // Synchronous Read Process
    always_ff @(posedge clk) begin
        read_data <= rom_data[addr];
    end

    // Unpacking
    assign out_in_ch          = read_data[9:0];
    assign out_out_ch         = read_data[19:10];
    assign out_width          = read_data[27:20];
    assign out_height         = read_data[35:28];
    assign out_stride         = read_data[37:36];
    assign out_has_prelu      = read_data[38];
    assign out_ping_pong_flag = read_data[39];

endmodule
