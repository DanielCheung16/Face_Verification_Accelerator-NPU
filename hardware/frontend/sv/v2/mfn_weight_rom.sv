// ==============================================================================
// Module: mfn_weight_rom (v2)
// Dual-port read: addr_a for c_out, addr_b for c_out+1 (Item 5 dual MAC).
// ==============================================================================

module mfn_weight_rom #(
    parameter int DWIDTH = 16
)(
    input  logic              clk,
    input  logic [19:0]       addr_a,
    input  logic [19:0]       addr_b,
    output logic signed [DWIDTH-1:0] weights_a [0:8],
    output logic signed [DWIDTH-1:0] weights_b [0:8]
);

    logic signed [DWIDTH-1:0] mem [0:1048575];

    initial begin
        for (int i=0; i<1048576; i++) mem[i] = '0;
        $readmemh("hex/weights.hex", mem);
    end

    always_comb begin
        for (int i = 0; i < 9; i++) begin
            weights_a[i] = (addr_a + i < 1048576) ? mem[addr_a + i] : '0;
            weights_b[i] = (addr_b + i < 1048576) ? mem[addr_b + i] : '0;
        end
    end

endmodule
