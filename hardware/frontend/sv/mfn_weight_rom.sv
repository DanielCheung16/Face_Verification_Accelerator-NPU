// ==============================================================================
// Module: mfn_weight_rom
// Description: ROM for MobileFaceNet weights (16-bit). Combinatorial for Sim.
// ==============================================================================

module mfn_weight_rom #(
    parameter int DWIDTH = 16
)(
    input  logic              clk,
    input  logic [17:0]       addr,
    output logic signed [DWIDTH-1:0] weights_out [0:8]
);

    logic signed [DWIDTH-1:0] mem [0:262143];

    initial begin
        for (int i=0; i<262144; i++) mem[i] = '0;
        $readmemh("hex/weights.hex", mem);
    end

    // Combinatorial Read
    always_comb begin
        for (int i = 0; i < 9; i++) begin
            if (addr + i < 262144)
                weights_out[i] = mem[addr + i];
            else
                weights_out[i] = '0;
        end
    end

endmodule
