// ============================================================
// netlist_beh.sv — Behavioral overrides for empty stubs in
//                  mfn_frontend_top_v2_syn.v (gate-level sim)
//
// Module names match the parameter-specialised names Genus uses:
//   mfn_psum_sram_AWIDTH40
//   mfn_weight_rom_DWIDTH16  (uses escaped-identifier ports)
//   mfn_bias_rom_DWIDTH32
//   mfn_prelu_rom_DWIDTH16
//   mfn_layer_config_rom
//
// Compile this file BEFORE the stripped netlist so Xcelium picks
// up these definitions and finds no duplicate when parsing the netlist.
// ============================================================

// -- psum_sram: 512×40-bit, 2W 3R, async read ----------------─
module mfn_psum_sram_AWIDTH40(
    input  logic              clk,
    input  logic              we_a,
    input  logic [8:0]        waddr_a,
    input  logic [39:0]       wdata_a,
    input  logic              we_b,
    input  logic [8:0]        waddr_b,
    input  logic [39:0]       wdata_b,
    input  logic [8:0]        raddr_a,
    output logic [39:0]       rdata_a,
    input  logic [8:0]        raddr_b,
    output logic [39:0]       rdata_b,
    input  logic [8:0]        raddr_c,
    output logic [39:0]       rdata_c
);
    logic [39:0] mem [0:511];
    initial foreach (mem[i]) mem[i] = '0;

    always_ff @(posedge clk) begin
        if (we_a) mem[waddr_a] <= wdata_a;
        if (we_b) mem[waddr_b] <= wdata_b;
    end

    assign rdata_a = mem[raddr_a];
    assign rdata_b = mem[raddr_b];
    assign rdata_c = mem[raddr_c];
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
