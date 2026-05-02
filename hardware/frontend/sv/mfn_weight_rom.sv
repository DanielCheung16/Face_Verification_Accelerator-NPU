// ==============================================================================
// Module: mfn_weight_rom
// Description: Wide-bus Weight ROM for MobileFaceNet MAC Array.
//              Outputs 9x16-bit weights, 32-bit bias, and 16-bit PReLU parameter
//              in a single cycle. (Total 192 bits per word)
// ==============================================================================

module mfn_weight_rom #(
    parameter int ADDR_WIDTH = 10, // 1024 entries
    parameter int DWIDTH = 16,
    parameter int BWIDTH = 32
)(
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] addr,
    
    // Unpacked outputs for easy access
    output logic signed [DWIDTH-1:0] wgt_out [0:8],
    output logic signed [BWIDTH-1:0] bias_out,
    output logic signed [DWIDTH-1:0] prelu_weight_out
);

    // 9 * 16 + 32 + 16 = 192
    localparam int ROM_WIDTH = 9 * DWIDTH + BWIDTH + DWIDTH;
    
    // Internal ROM array (can be synthesized to macro or block RAM)
    logic [ROM_WIDTH-1:0] rom_data [0:(1<<ADDR_WIDTH)-1];
    
    // Output register for synchronous read
    logic [ROM_WIDTH-1:0] read_data;

    // Initialization (In real ASIC, replace with memory compiler macro or $readmemh)
    initial begin
        // Initialize with zeros or test pattern
        for (int i = 0; i < (1<<ADDR_WIDTH); i++) begin
            rom_data[i] = '0;
        end
        // Example: load file
        $readmemh("weights.hex", rom_data);
    end

    // Synchronous Read Process
    always_ff @(posedge clk) begin
        read_data <= rom_data[addr];
    end

    // Unpacking logic
    generate
        for (genvar i = 0; i < 9; i++) begin : gen_unpack_weights
            assign wgt_out[i] = read_data[(i*DWIDTH) +: DWIDTH];
        end
    endgenerate
    
    assign bias_out         = read_data[9*DWIDTH +: BWIDTH];
    assign prelu_weight_out = read_data[9*DWIDTH+BWIDTH +: DWIDTH];

endmodule
