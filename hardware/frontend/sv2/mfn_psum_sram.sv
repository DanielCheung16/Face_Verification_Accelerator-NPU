// ==============================================================================
// Module: mfn_psum_sram
// 512×AWIDTH-bit partial-sum register file  (2 write ports, 3 read ports)
//
// Simulation: behavioral async-read / sync-write model (same semantics as FF array)
// Synthesis : empty stub in syn/v2_rom_stubs.sv → Genus treats as black box (0 cells)
//             The 512×40 = 20 480 FFs + 512-to-1 mux are gone from the netlist.
//
// Write port A : INIT_PSUM bias  OR  CLA_a result  (mutually exclusive, see ctrl)
// Write port B : CLA_b result for dual-MAC c_out+1  (enable_mac_b_d2 gated)
// Read  port A : CLA_a operand  (psum_mem[c_out_d2]  or [0] for DW)
// Read  port B : CLA_b operand  (psum_mem[c_out_d2+1])
// Read  port C : psum_to_act    (psum_mem[c_out_reg] or [0] for DW)
// ==============================================================================

module mfn_psum_sram #(
    parameter int AWIDTH = 40,
    parameter int DEPTH  = 512,
    parameter int ABITS  = 9
)(
    input  logic              clk,

    // Write port A
    input  logic              we_a,
    input  logic [ABITS-1:0]  waddr_a,
    input  logic [AWIDTH-1:0] wdata_a,

    // Write port B
    input  logic              we_b,
    input  logic [ABITS-1:0]  waddr_b,
    input  logic [AWIDTH-1:0] wdata_b,

    // Read port A (CLA_a operand)
    input  logic [ABITS-1:0]  raddr_a,
    output logic [AWIDTH-1:0] rdata_a,

    // Read port B (CLA_b operand)
    input  logic [ABITS-1:0]  raddr_b,
    output logic [AWIDTH-1:0] rdata_b,

    // Read port C (psum_to_act)
    input  logic [ABITS-1:0]  raddr_c,
    output logic [AWIDTH-1:0] rdata_c
);

    logic [AWIDTH-1:0] mem [0:DEPTH-1];

    // Synchronous write — same edge semantics as the old always_ff block
    always_ff @(posedge clk) begin
        if (we_a) mem[waddr_a] <= wdata_a;
        if (we_b) mem[waddr_b] <= wdata_b;
    end

    // Asynchronous read — matches current combinational access of psum_mem[]
    assign rdata_a = mem[raddr_a];
    assign rdata_b = mem[raddr_b];
    assign rdata_c = mem[raddr_c];

endmodule
