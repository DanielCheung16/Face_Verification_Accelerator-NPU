// ============================================================
// netlist_beh.sv — Behavioral overrides for empty stubs in
//                  mfn_frontend_top_v2_syn.v (gate-level sim)
//
// v2 new-syn: mfn_psum_sram_AWIDTH40 is now a real structural wrapper
// in the netlist (contains u_sram_a + u_sram_b). The two OpenRAM macro
// stubs are stripped and replaced with these behavioral models:
//   sram_psum_a_1rw1r0w_40_512_freepdk45  (1RW port A + 1R port B)
//   sram_psum_b_1rw0r0w_40_512_freepdk45  (1RW port A only)
//
// Other stubs unchanged:
//   mfn_weight_rom_DWIDTH16  (uses escaped-identifier ports)
//   mfn_bias_rom_DWIDTH32
//   mfn_prelu_rom_DWIDTH16
//   mfn_layer_config_rom
//
// Compile this file BEFORE the stripped netlist so Xcelium picks
// up these definitions and finds no duplicate when parsing the netlist.
// ============================================================

// -- OpenRAM SRAM_A: 512×40-bit, 1RW (port A) + 1R (port B) --
// Sync write / async read — matches mfn_psum_sram.sv RTL semantics.
// csb = chip-select bar (active low), web = write-enable bar (active low)
module sram_psum_a_1rw1r0w_40_512_freepdk45(
    input  logic        clk0, csb0, web0,
    input  logic [4:0]  wmask0,
    input  logic [8:0]  addr0,
    input  logic [39:0] din0,
    output logic [39:0] dout0,
    input  logic        clk1, csb1,
    input  logic [8:0]  addr1,
    output logic [39:0] dout1
);
    logic [39:0] mem [0:511];
    initial foreach (mem[i]) mem[i] = '0;

    // Synchronous write (port A)
    always_ff @(posedge clk0)
        if (!csb0 && !web0) begin
            if (wmask0[0]) mem[addr0][ 7: 0] <= din0[ 7: 0];
            if (wmask0[1]) mem[addr0][15: 8] <= din0[15: 8];
            if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
            if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            if (wmask0[4]) mem[addr0][39:32] <= din0[39:32];
        end

    // Asynchronous read — same semantics as RTL mfn_psum_sram.sv
    assign dout0 = mem[addr0];
    assign dout1 = mem[addr1];
endmodule

// -- OpenRAM SRAM_B: 512×40-bit, 1RW (port A only) -----------
// Sync write / async read — matches mfn_psum_sram.sv RTL semantics.
module sram_psum_b_1rw0r0w_40_512_freepdk45(
    input  logic        clk0, csb0, web0,
    input  logic [4:0]  wmask0,
    input  logic [8:0]  addr0,
    input  logic [39:0] din0,
    output logic [39:0] dout0
);
    logic [39:0] mem [0:511];
    initial foreach (mem[i]) mem[i] = '0;

    always_ff @(posedge clk0)
        if (!csb0 && !web0) begin
            if (wmask0[0]) mem[addr0][ 7: 0] <= din0[ 7: 0];
            if (wmask0[1]) mem[addr0][15: 8] <= din0[15: 8];
            if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
            if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            if (wmask0[4]) mem[addr0][39:32] <= din0[39:32];
        end

    assign dout0 = mem[addr0];
endmodule

// -- weight ROM: dual-port, 9 weights per port, escaped identifiers --
// Port ordering matches the synthesised stub exactly.
module mfn_weight_rom_DWIDTH16(
    input  logic              clk,
    input  logic [19:0]       addr_a,
    input  logic [19:0]       addr_b,
    output logic [15:0] \weights_a[8] ,
    output logic [15:0] \weights_a[7] ,
    output logic [15:0] \weights_a[6] ,
    output logic [15:0] \weights_a[5] ,
    output logic [15:0] \weights_a[4] ,
    output logic [15:0] \weights_a[3] ,
    output logic [15:0] \weights_a[2] ,
    output logic [15:0] \weights_a[1] ,
    output logic [15:0] \weights_a[0] ,
    output logic [15:0] \weights_b[8] ,
    output logic [15:0] \weights_b[7] ,
    output logic [15:0] \weights_b[6] ,
    output logic [15:0] \weights_b[5] ,
    output logic [15:0] \weights_b[4] ,
    output logic [15:0] \weights_b[3] ,
    output logic [15:0] \weights_b[2] ,
    output logic [15:0] \weights_b[1] ,
    output logic [15:0] \weights_b[0]
);
    logic [15:0] mem [0:1048575];
    initial begin
        foreach (mem[i]) mem[i] = '0;
        $readmemh("hex/weights.hex", mem);
    end

    // Combinational read — 9 consecutive entries from base address
    always_comb begin
        \weights_a[0] = mem[addr_a];
        \weights_a[1] = mem[addr_a + 20'd1];
        \weights_a[2] = mem[addr_a + 20'd2];
        \weights_a[3] = mem[addr_a + 20'd3];
        \weights_a[4] = mem[addr_a + 20'd4];
        \weights_a[5] = mem[addr_a + 20'd5];
        \weights_a[6] = mem[addr_a + 20'd6];
        \weights_a[7] = mem[addr_a + 20'd7];
        \weights_a[8] = mem[addr_a + 20'd8];
        \weights_b[0] = mem[addr_b];
        \weights_b[1] = mem[addr_b + 20'd1];
        \weights_b[2] = mem[addr_b + 20'd2];
        \weights_b[3] = mem[addr_b + 20'd3];
        \weights_b[4] = mem[addr_b + 20'd4];
        \weights_b[5] = mem[addr_b + 20'd5];
        \weights_b[6] = mem[addr_b + 20'd6];
        \weights_b[7] = mem[addr_b + 20'd7];
        \weights_b[8] = mem[addr_b + 20'd8];
    end
endmodule

// -- bias ROM: 16384×32-bit, combinational --------------------
module mfn_bias_rom_DWIDTH32(
    input  logic [13:0]       addr,
    output logic signed [31:0] bias_out
);
    logic signed [31:0] mem [0:16383];
    initial begin
        foreach (mem[i]) mem[i] = '0;
        $readmemh("hex/bias.hex", mem);
    end
    assign bias_out = mem[addr];
endmodule

// -- PReLU ROM: 16384×16-bit, combinational ------------------─
module mfn_prelu_rom_DWIDTH16(
    input  logic [13:0]       addr,
    output logic signed [15:0] prelu_out
);
    logic signed [15:0] mem [0:16383];
    initial begin
        foreach (mem[i]) mem[i] = '0;
        $readmemh("hex/prelu.hex", mem);
    end
    assign prelu_out = mem[addr];
endmodule

// -- Layer config ROM: 64×64-bit, registered read ------------─
module mfn_layer_config_rom(
    input  logic              clk,
    input  logic [5:0]        addr,
    output logic [63:0]       data_out
);
    logic [63:0] rom_data [0:63];
    initial begin
        foreach (rom_data[i]) rom_data[i] = '0;
        $readmemh("hex/config.hex", rom_data);
    end
    always_ff @(posedge clk)
        data_out <= rom_data[addr];
endmodule
