// ============================================================
// ROM Black-Box Stubs for Synthesis — v2
// Differences from rom_stubs.sv (v1):
//   mfn_weight_rom: dual-port (addr_a/addr_b, weights_a/weights_b)
//   mfn_bias_rom, mfn_prelu_rom, mfn_layer_config_rom: unchanged
// ============================================================

// Weight ROM v2: dual read ports for simultaneous c_out / c_out+1 access
module mfn_weight_rom #(parameter int DWIDTH = 16)(
    input  logic              clk,
    input  logic [19:0]       addr_a,
    input  logic [19:0]       addr_b,
    output logic signed [DWIDTH-1:0] weights_a [0:8],
    output logic signed [DWIDTH-1:0] weights_b [0:8]
);
endmodule

module mfn_bias_rom #(parameter int DWIDTH = 32)(
    input  logic [13:0]              addr,
    output logic signed [DWIDTH-1:0] bias_out
);
endmodule

module mfn_prelu_rom #(parameter int DWIDTH = 16)(
    input  logic [13:0]              addr,
    output logic signed [DWIDTH-1:0] prelu_out
);
endmodule

module mfn_layer_config_rom #(parameter int ADDR_WIDTH = 6)(
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [63:0]           data_out
);
endmodule

// psum_mem SRAM stub — synthesis sees a black box with 0 cells.
// Replaces the 512×40 FF array + 512-to-1 mux decode that caused
// 125 K cells and congestion-induced DRC/timing failures.
module mfn_psum_sram #(
    parameter int AWIDTH = 40,
    parameter int DEPTH  = 512,
    parameter int ABITS  = 9
)(
    input  logic              clk,
    input  logic              we_a,
    input  logic [ABITS-1:0]  waddr_a,
    input  logic [AWIDTH-1:0] wdata_a,
    input  logic              we_b,
    input  logic [ABITS-1:0]  waddr_b,
    input  logic [AWIDTH-1:0] wdata_b,
    input  logic [ABITS-1:0]  raddr_a,
    output logic [AWIDTH-1:0] rdata_a,
    input  logic [ABITS-1:0]  raddr_b,
    output logic [AWIDTH-1:0] rdata_b,
    input  logic [ABITS-1:0]  raddr_c,
    output logic [AWIDTH-1:0] rdata_c
);
endmodule
