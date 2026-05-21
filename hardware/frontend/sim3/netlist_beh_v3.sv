// ============================================================
// netlist_beh_v3.sv — Behavioral models for the empty black-box
//   stubs in mfn_frontend_top_v3_syn.v (gate-level simulation).
//
// Provides:  mfn_bias_rom  mfn_prelu_rom  mfn_layer_config_rom
//            mfn_weight_rom_v3_SA_ROWS12_SA_COLS12  (mangled name)
//            sram_psum_a_1rw1r0w_40_512_freepdk45   (psum SRAM macro)
// (act_buf SRAM model is compiled separately: sv3/sram_act_buf_*.sv)
//
// Compile BEFORE the stripped netlist so Xcelium binds these defs.
// strip_stubs.py removes the 4 ROM stubs from the netlist first.
// ============================================================

// -- psum SRAM_A: 512x40-bit, 1RW (port A) + 1R (port B) -------
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
    always_ff @(posedge clk0)
        if (!csb0 && !web0) begin
            if (wmask0[0]) mem[addr0][ 7: 0] <= din0[ 7: 0];
            if (wmask0[1]) mem[addr0][15: 8] <= din0[15: 8];
            if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
            if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            if (wmask0[4]) mem[addr0][39:32] <= din0[39:32];
        end
    assign dout0 = mem[addr0];
    assign dout1 = mem[addr1];
endmodule

// -- bias ROM: 16384x32-bit, combinational --------------------
module mfn_bias_rom(
    input  logic [13:0]        addr,
    output logic signed [31:0] bias_out
);
    logic signed [31:0] mem [0:16383];
    initial begin
        foreach (mem[i]) mem[i] = '0;
        $readmemh("hex/bias.hex", mem);
    end
    assign bias_out = mem[addr];
endmodule

// -- PReLU ROM: 16384x16-bit, combinational -------------------
module mfn_prelu_rom(
    input  logic [13:0]        addr,
    output logic signed [15:0] prelu_out
);
    logic signed [15:0] mem [0:16383];
    initial begin
        foreach (mem[i]) mem[i] = '0;
        $readmemh("hex/prelu.hex", mem);
    end
    assign prelu_out = mem[addr];
endmodule

// -- layer config ROM: 64x64-bit, registered read -------------
module mfn_layer_config_rom(
    input  logic        clk,
    input  logic [5:0]  addr,
    output logic [63:0] data_out
);
    logic [63:0] rom_data [0:63];
    initial begin
        foreach (rom_data[i]) rom_data[i] = '0;
        $readmemh("hex/config.hex", rom_data);
    end
    always_ff @(posedge clk) data_out <= rom_data[addr];
endmodule

// -- weight ROM v3: 12-port, 12 weights/port, combinational ---
//    escaped-identifier ports match the parameter-mangled netlist
//    module name mfn_weight_rom_v3_SA_ROWS12_SA_COLS12.
module mfn_weight_rom_v3_SA_ROWS12_SA_COLS12(
    \addr[0] , \addr[1] , \addr[2] , \addr[3] , \addr[4] , \addr[5] ,
    \addr[6] , \addr[7] , \addr[8] , \addr[9] , \addr[10] , \addr[11] ,
    \wgt_out[0][0] , \wgt_out[0][1] , \wgt_out[0][2] , \wgt_out[0][3] , \wgt_out[0][4] , \wgt_out[0][5] ,
    \wgt_out[0][6] , \wgt_out[0][7] , \wgt_out[0][8] , \wgt_out[0][9] , \wgt_out[0][10] , \wgt_out[0][11] ,
    \wgt_out[1][0] , \wgt_out[1][1] , \wgt_out[1][2] , \wgt_out[1][3] , \wgt_out[1][4] , \wgt_out[1][5] ,
    \wgt_out[1][6] , \wgt_out[1][7] , \wgt_out[1][8] , \wgt_out[1][9] , \wgt_out[1][10] , \wgt_out[1][11] ,
    \wgt_out[2][0] , \wgt_out[2][1] , \wgt_out[2][2] , \wgt_out[2][3] , \wgt_out[2][4] , \wgt_out[2][5] ,
    \wgt_out[2][6] , \wgt_out[2][7] , \wgt_out[2][8] , \wgt_out[2][9] , \wgt_out[2][10] , \wgt_out[2][11] ,
    \wgt_out[3][0] , \wgt_out[3][1] , \wgt_out[3][2] , \wgt_out[3][3] , \wgt_out[3][4] , \wgt_out[3][5] ,
    \wgt_out[3][6] , \wgt_out[3][7] , \wgt_out[3][8] , \wgt_out[3][9] , \wgt_out[3][10] , \wgt_out[3][11] ,
    \wgt_out[4][0] , \wgt_out[4][1] , \wgt_out[4][2] , \wgt_out[4][3] , \wgt_out[4][4] , \wgt_out[4][5] ,
    \wgt_out[4][6] , \wgt_out[4][7] , \wgt_out[4][8] , \wgt_out[4][9] , \wgt_out[4][10] , \wgt_out[4][11] ,
    \wgt_out[5][0] , \wgt_out[5][1] , \wgt_out[5][2] , \wgt_out[5][3] , \wgt_out[5][4] , \wgt_out[5][5] ,
    \wgt_out[5][6] , \wgt_out[5][7] , \wgt_out[5][8] , \wgt_out[5][9] , \wgt_out[5][10] , \wgt_out[5][11] ,
    \wgt_out[6][0] , \wgt_out[6][1] , \wgt_out[6][2] , \wgt_out[6][3] , \wgt_out[6][4] , \wgt_out[6][5] ,
    \wgt_out[6][6] , \wgt_out[6][7] , \wgt_out[6][8] , \wgt_out[6][9] , \wgt_out[6][10] , \wgt_out[6][11] ,
    \wgt_out[7][0] , \wgt_out[7][1] , \wgt_out[7][2] , \wgt_out[7][3] , \wgt_out[7][4] , \wgt_out[7][5] ,
    \wgt_out[7][6] , \wgt_out[7][7] , \wgt_out[7][8] , \wgt_out[7][9] , \wgt_out[7][10] , \wgt_out[7][11] ,
    \wgt_out[8][0] , \wgt_out[8][1] , \wgt_out[8][2] , \wgt_out[8][3] , \wgt_out[8][4] , \wgt_out[8][5] ,
    \wgt_out[8][6] , \wgt_out[8][7] , \wgt_out[8][8] , \wgt_out[8][9] , \wgt_out[8][10] , \wgt_out[8][11] ,
    \wgt_out[9][0] , \wgt_out[9][1] , \wgt_out[9][2] , \wgt_out[9][3] , \wgt_out[9][4] , \wgt_out[9][5] ,
    \wgt_out[9][6] , \wgt_out[9][7] , \wgt_out[9][8] , \wgt_out[9][9] , \wgt_out[9][10] , \wgt_out[9][11] ,
    \wgt_out[10][0] , \wgt_out[10][1] , \wgt_out[10][2] , \wgt_out[10][3] , \wgt_out[10][4] , \wgt_out[10][5] ,
    \wgt_out[10][6] , \wgt_out[10][7] , \wgt_out[10][8] , \wgt_out[10][9] , \wgt_out[10][10] , \wgt_out[10][11] ,
    \wgt_out[11][0] , \wgt_out[11][1] , \wgt_out[11][2] , \wgt_out[11][3] , \wgt_out[11][4] , \wgt_out[11][5] ,
    \wgt_out[11][6] , \wgt_out[11][7] , \wgt_out[11][8] , \wgt_out[11][9] , \wgt_out[11][10] , \wgt_out[11][11] 
);
  input  [19:0] \addr[0] ;
  input  [19:0] \addr[1] ;
  input  [19:0] \addr[2] ;
  input  [19:0] \addr[3] ;
  input  [19:0] \addr[4] ;
  input  [19:0] \addr[5] ;
  input  [19:0] \addr[6] ;
  input  [19:0] \addr[7] ;
  input  [19:0] \addr[8] ;
  input  [19:0] \addr[9] ;
  input  [19:0] \addr[10] ;
  input  [19:0] \addr[11] ;
  output [15:0] \wgt_out[0][0] ;
  output [15:0] \wgt_out[0][1] ;
  output [15:0] \wgt_out[0][2] ;
  output [15:0] \wgt_out[0][3] ;
  output [15:0] \wgt_out[0][4] ;
  output [15:0] \wgt_out[0][5] ;
  output [15:0] \wgt_out[0][6] ;
  output [15:0] \wgt_out[0][7] ;
  output [15:0] \wgt_out[0][8] ;
  output [15:0] \wgt_out[0][9] ;
  output [15:0] \wgt_out[0][10] ;
  output [15:0] \wgt_out[0][11] ;
  output [15:0] \wgt_out[1][0] ;
  output [15:0] \wgt_out[1][1] ;
  output [15:0] \wgt_out[1][2] ;
  output [15:0] \wgt_out[1][3] ;
  output [15:0] \wgt_out[1][4] ;
  output [15:0] \wgt_out[1][5] ;
  output [15:0] \wgt_out[1][6] ;
  output [15:0] \wgt_out[1][7] ;
  output [15:0] \wgt_out[1][8] ;
  output [15:0] \wgt_out[1][9] ;
  output [15:0] \wgt_out[1][10] ;
  output [15:0] \wgt_out[1][11] ;
  output [15:0] \wgt_out[2][0] ;
  output [15:0] \wgt_out[2][1] ;
  output [15:0] \wgt_out[2][2] ;
  output [15:0] \wgt_out[2][3] ;
  output [15:0] \wgt_out[2][4] ;
  output [15:0] \wgt_out[2][5] ;
  output [15:0] \wgt_out[2][6] ;
  output [15:0] \wgt_out[2][7] ;
  output [15:0] \wgt_out[2][8] ;
  output [15:0] \wgt_out[2][9] ;
  output [15:0] \wgt_out[2][10] ;
  output [15:0] \wgt_out[2][11] ;
  output [15:0] \wgt_out[3][0] ;
  output [15:0] \wgt_out[3][1] ;
  output [15:0] \wgt_out[3][2] ;
  output [15:0] \wgt_out[3][3] ;
  output [15:0] \wgt_out[3][4] ;
  output [15:0] \wgt_out[3][5] ;
  output [15:0] \wgt_out[3][6] ;
  output [15:0] \wgt_out[3][7] ;
  output [15:0] \wgt_out[3][8] ;
  output [15:0] \wgt_out[3][9] ;
  output [15:0] \wgt_out[3][10] ;
  output [15:0] \wgt_out[3][11] ;
  output [15:0] \wgt_out[4][0] ;
  output [15:0] \wgt_out[4][1] ;
  output [15:0] \wgt_out[4][2] ;
  output [15:0] \wgt_out[4][3] ;
  output [15:0] \wgt_out[4][4] ;
  output [15:0] \wgt_out[4][5] ;
  output [15:0] \wgt_out[4][6] ;
  output [15:0] \wgt_out[4][7] ;
  output [15:0] \wgt_out[4][8] ;
  output [15:0] \wgt_out[4][9] ;
  output [15:0] \wgt_out[4][10] ;
  output [15:0] \wgt_out[4][11] ;
  output [15:0] \wgt_out[5][0] ;
  output [15:0] \wgt_out[5][1] ;
  output [15:0] \wgt_out[5][2] ;
  output [15:0] \wgt_out[5][3] ;
  output [15:0] \wgt_out[5][4] ;
  output [15:0] \wgt_out[5][5] ;
  output [15:0] \wgt_out[5][6] ;
  output [15:0] \wgt_out[5][7] ;
  output [15:0] \wgt_out[5][8] ;
  output [15:0] \wgt_out[5][9] ;
  output [15:0] \wgt_out[5][10] ;
  output [15:0] \wgt_out[5][11] ;
  output [15:0] \wgt_out[6][0] ;
  output [15:0] \wgt_out[6][1] ;
  output [15:0] \wgt_out[6][2] ;
  output [15:0] \wgt_out[6][3] ;
  output [15:0] \wgt_out[6][4] ;
  output [15:0] \wgt_out[6][5] ;
  output [15:0] \wgt_out[6][6] ;
  output [15:0] \wgt_out[6][7] ;
  output [15:0] \wgt_out[6][8] ;
  output [15:0] \wgt_out[6][9] ;
  output [15:0] \wgt_out[6][10] ;
  output [15:0] \wgt_out[6][11] ;
  output [15:0] \wgt_out[7][0] ;
  output [15:0] \wgt_out[7][1] ;
  output [15:0] \wgt_out[7][2] ;
  output [15:0] \wgt_out[7][3] ;
  output [15:0] \wgt_out[7][4] ;
  output [15:0] \wgt_out[7][5] ;
  output [15:0] \wgt_out[7][6] ;
  output [15:0] \wgt_out[7][7] ;
  output [15:0] \wgt_out[7][8] ;
  output [15:0] \wgt_out[7][9] ;
  output [15:0] \wgt_out[7][10] ;
  output [15:0] \wgt_out[7][11] ;
  output [15:0] \wgt_out[8][0] ;
  output [15:0] \wgt_out[8][1] ;
  output [15:0] \wgt_out[8][2] ;
  output [15:0] \wgt_out[8][3] ;
  output [15:0] \wgt_out[8][4] ;
  output [15:0] \wgt_out[8][5] ;
  output [15:0] \wgt_out[8][6] ;
  output [15:0] \wgt_out[8][7] ;
  output [15:0] \wgt_out[8][8] ;
  output [15:0] \wgt_out[8][9] ;
  output [15:0] \wgt_out[8][10] ;
  output [15:0] \wgt_out[8][11] ;
  output [15:0] \wgt_out[9][0] ;
  output [15:0] \wgt_out[9][1] ;
  output [15:0] \wgt_out[9][2] ;
  output [15:0] \wgt_out[9][3] ;
  output [15:0] \wgt_out[9][4] ;
  output [15:0] \wgt_out[9][5] ;
  output [15:0] \wgt_out[9][6] ;
  output [15:0] \wgt_out[9][7] ;
  output [15:0] \wgt_out[9][8] ;
  output [15:0] \wgt_out[9][9] ;
  output [15:0] \wgt_out[9][10] ;
  output [15:0] \wgt_out[9][11] ;
  output [15:0] \wgt_out[10][0] ;
  output [15:0] \wgt_out[10][1] ;
  output [15:0] \wgt_out[10][2] ;
  output [15:0] \wgt_out[10][3] ;
  output [15:0] \wgt_out[10][4] ;
  output [15:0] \wgt_out[10][5] ;
  output [15:0] \wgt_out[10][6] ;
  output [15:0] \wgt_out[10][7] ;
  output [15:0] \wgt_out[10][8] ;
  output [15:0] \wgt_out[10][9] ;
  output [15:0] \wgt_out[10][10] ;
  output [15:0] \wgt_out[10][11] ;
  output [15:0] \wgt_out[11][0] ;
  output [15:0] \wgt_out[11][1] ;
  output [15:0] \wgt_out[11][2] ;
  output [15:0] \wgt_out[11][3] ;
  output [15:0] \wgt_out[11][4] ;
  output [15:0] \wgt_out[11][5] ;
  output [15:0] \wgt_out[11][6] ;
  output [15:0] \wgt_out[11][7] ;
  output [15:0] \wgt_out[11][8] ;
  output [15:0] \wgt_out[11][9] ;
  output [15:0] \wgt_out[11][10] ;
  output [15:0] \wgt_out[11][11] ;
  reg [15:0] mem [0:1048575];
  integer i;
  initial begin
    for (i = 0; i < 1048576; i = i + 1) mem[i] = 16'd0;
    $readmemh("hex/weights.hex", mem);
  end
  assign \wgt_out[0][0]  = mem[\addr[0]  + 20'd0];
  assign \wgt_out[0][1]  = mem[\addr[0]  + 20'd1];
  assign \wgt_out[0][2]  = mem[\addr[0]  + 20'd2];
  assign \wgt_out[0][3]  = mem[\addr[0]  + 20'd3];
  assign \wgt_out[0][4]  = mem[\addr[0]  + 20'd4];
  assign \wgt_out[0][5]  = mem[\addr[0]  + 20'd5];
  assign \wgt_out[0][6]  = mem[\addr[0]  + 20'd6];
  assign \wgt_out[0][7]  = mem[\addr[0]  + 20'd7];
  assign \wgt_out[0][8]  = mem[\addr[0]  + 20'd8];
  assign \wgt_out[0][9]  = mem[\addr[0]  + 20'd9];
  assign \wgt_out[0][10]  = mem[\addr[0]  + 20'd10];
  assign \wgt_out[0][11]  = mem[\addr[0]  + 20'd11];
  assign \wgt_out[1][0]  = mem[\addr[1]  + 20'd0];
  assign \wgt_out[1][1]  = mem[\addr[1]  + 20'd1];
  assign \wgt_out[1][2]  = mem[\addr[1]  + 20'd2];
  assign \wgt_out[1][3]  = mem[\addr[1]  + 20'd3];
  assign \wgt_out[1][4]  = mem[\addr[1]  + 20'd4];
  assign \wgt_out[1][5]  = mem[\addr[1]  + 20'd5];
  assign \wgt_out[1][6]  = mem[\addr[1]  + 20'd6];
  assign \wgt_out[1][7]  = mem[\addr[1]  + 20'd7];
  assign \wgt_out[1][8]  = mem[\addr[1]  + 20'd8];
  assign \wgt_out[1][9]  = mem[\addr[1]  + 20'd9];
  assign \wgt_out[1][10]  = mem[\addr[1]  + 20'd10];
  assign \wgt_out[1][11]  = mem[\addr[1]  + 20'd11];
  assign \wgt_out[2][0]  = mem[\addr[2]  + 20'd0];
  assign \wgt_out[2][1]  = mem[\addr[2]  + 20'd1];
  assign \wgt_out[2][2]  = mem[\addr[2]  + 20'd2];
  assign \wgt_out[2][3]  = mem[\addr[2]  + 20'd3];
  assign \wgt_out[2][4]  = mem[\addr[2]  + 20'd4];
  assign \wgt_out[2][5]  = mem[\addr[2]  + 20'd5];
  assign \wgt_out[2][6]  = mem[\addr[2]  + 20'd6];
  assign \wgt_out[2][7]  = mem[\addr[2]  + 20'd7];
  assign \wgt_out[2][8]  = mem[\addr[2]  + 20'd8];
  assign \wgt_out[2][9]  = mem[\addr[2]  + 20'd9];
  assign \wgt_out[2][10]  = mem[\addr[2]  + 20'd10];
  assign \wgt_out[2][11]  = mem[\addr[2]  + 20'd11];
  assign \wgt_out[3][0]  = mem[\addr[3]  + 20'd0];
  assign \wgt_out[3][1]  = mem[\addr[3]  + 20'd1];
  assign \wgt_out[3][2]  = mem[\addr[3]  + 20'd2];
  assign \wgt_out[3][3]  = mem[\addr[3]  + 20'd3];
  assign \wgt_out[3][4]  = mem[\addr[3]  + 20'd4];
  assign \wgt_out[3][5]  = mem[\addr[3]  + 20'd5];
  assign \wgt_out[3][6]  = mem[\addr[3]  + 20'd6];
  assign \wgt_out[3][7]  = mem[\addr[3]  + 20'd7];
  assign \wgt_out[3][8]  = mem[\addr[3]  + 20'd8];
  assign \wgt_out[3][9]  = mem[\addr[3]  + 20'd9];
  assign \wgt_out[3][10]  = mem[\addr[3]  + 20'd10];
  assign \wgt_out[3][11]  = mem[\addr[3]  + 20'd11];
  assign \wgt_out[4][0]  = mem[\addr[4]  + 20'd0];
  assign \wgt_out[4][1]  = mem[\addr[4]  + 20'd1];
  assign \wgt_out[4][2]  = mem[\addr[4]  + 20'd2];
  assign \wgt_out[4][3]  = mem[\addr[4]  + 20'd3];
  assign \wgt_out[4][4]  = mem[\addr[4]  + 20'd4];
  assign \wgt_out[4][5]  = mem[\addr[4]  + 20'd5];
  assign \wgt_out[4][6]  = mem[\addr[4]  + 20'd6];
  assign \wgt_out[4][7]  = mem[\addr[4]  + 20'd7];
  assign \wgt_out[4][8]  = mem[\addr[4]  + 20'd8];
  assign \wgt_out[4][9]  = mem[\addr[4]  + 20'd9];
  assign \wgt_out[4][10]  = mem[\addr[4]  + 20'd10];
  assign \wgt_out[4][11]  = mem[\addr[4]  + 20'd11];
  assign \wgt_out[5][0]  = mem[\addr[5]  + 20'd0];
  assign \wgt_out[5][1]  = mem[\addr[5]  + 20'd1];
  assign \wgt_out[5][2]  = mem[\addr[5]  + 20'd2];
  assign \wgt_out[5][3]  = mem[\addr[5]  + 20'd3];
  assign \wgt_out[5][4]  = mem[\addr[5]  + 20'd4];
  assign \wgt_out[5][5]  = mem[\addr[5]  + 20'd5];
  assign \wgt_out[5][6]  = mem[\addr[5]  + 20'd6];
  assign \wgt_out[5][7]  = mem[\addr[5]  + 20'd7];
  assign \wgt_out[5][8]  = mem[\addr[5]  + 20'd8];
  assign \wgt_out[5][9]  = mem[\addr[5]  + 20'd9];
  assign \wgt_out[5][10]  = mem[\addr[5]  + 20'd10];
  assign \wgt_out[5][11]  = mem[\addr[5]  + 20'd11];
  assign \wgt_out[6][0]  = mem[\addr[6]  + 20'd0];
  assign \wgt_out[6][1]  = mem[\addr[6]  + 20'd1];
  assign \wgt_out[6][2]  = mem[\addr[6]  + 20'd2];
  assign \wgt_out[6][3]  = mem[\addr[6]  + 20'd3];
  assign \wgt_out[6][4]  = mem[\addr[6]  + 20'd4];
  assign \wgt_out[6][5]  = mem[\addr[6]  + 20'd5];
  assign \wgt_out[6][6]  = mem[\addr[6]  + 20'd6];
  assign \wgt_out[6][7]  = mem[\addr[6]  + 20'd7];
  assign \wgt_out[6][8]  = mem[\addr[6]  + 20'd8];
  assign \wgt_out[6][9]  = mem[\addr[6]  + 20'd9];
  assign \wgt_out[6][10]  = mem[\addr[6]  + 20'd10];
  assign \wgt_out[6][11]  = mem[\addr[6]  + 20'd11];
  assign \wgt_out[7][0]  = mem[\addr[7]  + 20'd0];
  assign \wgt_out[7][1]  = mem[\addr[7]  + 20'd1];
  assign \wgt_out[7][2]  = mem[\addr[7]  + 20'd2];
  assign \wgt_out[7][3]  = mem[\addr[7]  + 20'd3];
  assign \wgt_out[7][4]  = mem[\addr[7]  + 20'd4];
  assign \wgt_out[7][5]  = mem[\addr[7]  + 20'd5];
  assign \wgt_out[7][6]  = mem[\addr[7]  + 20'd6];
  assign \wgt_out[7][7]  = mem[\addr[7]  + 20'd7];
  assign \wgt_out[7][8]  = mem[\addr[7]  + 20'd8];
  assign \wgt_out[7][9]  = mem[\addr[7]  + 20'd9];
  assign \wgt_out[7][10]  = mem[\addr[7]  + 20'd10];
  assign \wgt_out[7][11]  = mem[\addr[7]  + 20'd11];
  assign \wgt_out[8][0]  = mem[\addr[8]  + 20'd0];
  assign \wgt_out[8][1]  = mem[\addr[8]  + 20'd1];
  assign \wgt_out[8][2]  = mem[\addr[8]  + 20'd2];
  assign \wgt_out[8][3]  = mem[\addr[8]  + 20'd3];
  assign \wgt_out[8][4]  = mem[\addr[8]  + 20'd4];
  assign \wgt_out[8][5]  = mem[\addr[8]  + 20'd5];
  assign \wgt_out[8][6]  = mem[\addr[8]  + 20'd6];
  assign \wgt_out[8][7]  = mem[\addr[8]  + 20'd7];
  assign \wgt_out[8][8]  = mem[\addr[8]  + 20'd8];
  assign \wgt_out[8][9]  = mem[\addr[8]  + 20'd9];
  assign \wgt_out[8][10]  = mem[\addr[8]  + 20'd10];
  assign \wgt_out[8][11]  = mem[\addr[8]  + 20'd11];
  assign \wgt_out[9][0]  = mem[\addr[9]  + 20'd0];
  assign \wgt_out[9][1]  = mem[\addr[9]  + 20'd1];
  assign \wgt_out[9][2]  = mem[\addr[9]  + 20'd2];
  assign \wgt_out[9][3]  = mem[\addr[9]  + 20'd3];
  assign \wgt_out[9][4]  = mem[\addr[9]  + 20'd4];
  assign \wgt_out[9][5]  = mem[\addr[9]  + 20'd5];
  assign \wgt_out[9][6]  = mem[\addr[9]  + 20'd6];
  assign \wgt_out[9][7]  = mem[\addr[9]  + 20'd7];
  assign \wgt_out[9][8]  = mem[\addr[9]  + 20'd8];
  assign \wgt_out[9][9]  = mem[\addr[9]  + 20'd9];
  assign \wgt_out[9][10]  = mem[\addr[9]  + 20'd10];
  assign \wgt_out[9][11]  = mem[\addr[9]  + 20'd11];
  assign \wgt_out[10][0]  = mem[\addr[10]  + 20'd0];
  assign \wgt_out[10][1]  = mem[\addr[10]  + 20'd1];
  assign \wgt_out[10][2]  = mem[\addr[10]  + 20'd2];
  assign \wgt_out[10][3]  = mem[\addr[10]  + 20'd3];
  assign \wgt_out[10][4]  = mem[\addr[10]  + 20'd4];
  assign \wgt_out[10][5]  = mem[\addr[10]  + 20'd5];
  assign \wgt_out[10][6]  = mem[\addr[10]  + 20'd6];
  assign \wgt_out[10][7]  = mem[\addr[10]  + 20'd7];
  assign \wgt_out[10][8]  = mem[\addr[10]  + 20'd8];
  assign \wgt_out[10][9]  = mem[\addr[10]  + 20'd9];
  assign \wgt_out[10][10]  = mem[\addr[10]  + 20'd10];
  assign \wgt_out[10][11]  = mem[\addr[10]  + 20'd11];
  assign \wgt_out[11][0]  = mem[\addr[11]  + 20'd0];
  assign \wgt_out[11][1]  = mem[\addr[11]  + 20'd1];
  assign \wgt_out[11][2]  = mem[\addr[11]  + 20'd2];
  assign \wgt_out[11][3]  = mem[\addr[11]  + 20'd3];
  assign \wgt_out[11][4]  = mem[\addr[11]  + 20'd4];
  assign \wgt_out[11][5]  = mem[\addr[11]  + 20'd5];
  assign \wgt_out[11][6]  = mem[\addr[11]  + 20'd6];
  assign \wgt_out[11][7]  = mem[\addr[11]  + 20'd7];
  assign \wgt_out[11][8]  = mem[\addr[11]  + 20'd8];
  assign \wgt_out[11][9]  = mem[\addr[11]  + 20'd9];
  assign \wgt_out[11][10]  = mem[\addr[11]  + 20'd10];
  assign \wgt_out[11][11]  = mem[\addr[11]  + 20'd11];
endmodule
