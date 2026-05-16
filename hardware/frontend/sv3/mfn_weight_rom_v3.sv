// =============================================================================
// mfn_weight_rom_v3.sv — 12-port weight memory for v3 systolic array
//
// Academic model: each SA row gets its own address and reads SA_COLS consecutive
// weights per cycle. In real hardware this would be SA_ROWS SRAM banks (one per
// row), each holding 1/SA_ROWS of the weight data (striped by c_out index mod 12),
// with each bank providing SA_COLS=12 entries per cycle via a wide read port.
//
// Same hex file and layout as v2 — no repacking required.
// Row r reads from:
//   addr[r]          = layer_wgt_base + (c_out_tile+r)*wgt_step + c_in_tile
//   wgt_out[r][0..11] = mem[addr[r] .. addr[r]+11]
// =============================================================================

module mfn_weight_rom_v3 #(
    parameter int DWIDTH   = 16,
    parameter int MEM_BITS = 20,       // address width (up to 1M entries)
    parameter int SA_ROWS  = 12,
    parameter int SA_COLS  = 12
)(
    input  logic [MEM_BITS-1:0]      addr    [SA_ROWS],       // 12 base addresses
    output logic signed [DWIDTH-1:0] wgt_out [SA_ROWS][SA_COLS] // 12×12 weights
);
    logic signed [DWIDTH-1:0] mem [0:(1<<MEM_BITS)-1];

    initial begin
        foreach (mem[i]) mem[i] = '0;
        $readmemh("hex/weights.hex", mem);
    end

    // Fully combinational: SA_ROWS × SA_COLS concurrent reads
    always_comb
        for (int r = 0; r < SA_ROWS; r++)
            for (int c = 0; c < SA_COLS; c++)
                wgt_out[r][c] = mem[addr[r] + c[MEM_BITS-1:0]];
endmodule
