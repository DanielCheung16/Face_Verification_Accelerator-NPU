// ============================================================
// ROM Black-Box Stubs for Synthesis
// These replace the simulation-only $readmemh-based ROMs.
// Genus treats empty module bodies as black boxes and
// preserves the port interface without synthesizing content.
// In a full ASIC flow these would be replaced by:
//   - Weight ROM  → SRAM macro from OpenRAM/foundry
//   - Bias/PReLU  → Standard-cell ROM (case statement) or small SRAM
//   - Config ROM  → Standard-cell ROM (50-entry × 64-bit)
// ============================================================

// Weight ROM: 1M × 16-bit, outputs 9 words per cycle
// Would be replaced by SRAM macro (~16 Mbit) in physical design
module mfn_weight_rom #(parameter int DWIDTH = 16)(
    input  logic              clk,
    input  logic [19:0]       addr,
    output logic signed [DWIDTH-1:0] weights_out [0:8]
);
endmodule

// Bias ROM: 16K × 32-bit (Q20 fixed-point)
module mfn_bias_rom #(parameter int DWIDTH = 32)(
    input  logic [13:0]              addr,
    output logic signed [DWIDTH-1:0] bias_out
);
endmodule

// PReLU ROM: 16K × 16-bit (Q10 fixed-point alpha)
module mfn_prelu_rom #(parameter int DWIDTH = 16)(
    input  logic [13:0]              addr,
    output logic signed [DWIDTH-1:0] prelu_out
);
endmodule

// Layer Config ROM: 64 × 64-bit packed config words
module mfn_layer_config_rom #(parameter int ADDR_WIDTH = 6)(
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [63:0]           data_out
);
endmodule
