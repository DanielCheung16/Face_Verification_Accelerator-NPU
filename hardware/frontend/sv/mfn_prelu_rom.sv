// ==============================================================================
// Module: mfn_prelu_rom
// Description: ROM for MobileFaceNet PReLU weights (16-bit).
// ==============================================================================

module mfn_prelu_rom #(
    parameter int DWIDTH = 16
)(
    input  logic [13:0]       addr,
    output logic signed [DWIDTH-1:0] prelu_out
);

    logic signed [DWIDTH-1:0] mem [0:16383];

    initial begin
        for (int i=0; i<16384; i++) mem[i] = '0;
        $readmemh("hex/prelu.hex", mem);
    end

    assign prelu_out = mem[addr];

endmodule
