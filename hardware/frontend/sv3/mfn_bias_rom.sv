// ==============================================================================
// Module: mfn_bias_rom
// Description: ROM for MobileFaceNet biases (32-bit).
// ==============================================================================

module mfn_bias_rom #(
    parameter int DWIDTH = 32
)(
    input  logic [13:0]       addr,
    output logic signed [DWIDTH-1:0] bias_out
);

    logic signed [DWIDTH-1:0] mem [0:16383];

    initial begin
        for (int i=0; i<16384; i++) mem[i] = '0;
        $readmemh("hex/bias.hex", mem);
    end

    assign bias_out = mem[addr];

endmodule
