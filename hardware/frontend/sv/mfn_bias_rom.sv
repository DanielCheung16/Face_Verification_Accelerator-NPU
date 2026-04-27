// ==============================================================================
// Module: mfn_bias_rom
// Description: ROM for MobileFaceNet biases (32-bit).
// ==============================================================================

module mfn_bias_rom #(
    parameter int DWIDTH = 32
)(
    input  logic [9:0]        addr,
    output logic signed [DWIDTH-1:0] bias_out
);

    logic signed [DWIDTH-1:0] mem [0:1023];

    initial begin
        for (int i=0; i<1024; i++) mem[i] = '0;
        $readmemh("bias.hex", mem);
    end

    assign bias_out = mem[addr];

endmodule
