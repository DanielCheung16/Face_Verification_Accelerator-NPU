// ==============================================================================
// Module: mfn_layer_config_rom
// Description: Configuration ROM (64-bit packed) with DW-Conv and wgt_base.
// Format: {reserved(5), wgt_base(18), is_dw(1), pp(1), prelu(1), stride(2),
//          h(8), w(8), out_ch(10), in_ch(10)}
// ==============================================================================

module mfn_layer_config_rom #(
    parameter int ADDR_WIDTH = 6
)(
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [63:0]           data_out
);

    logic [63:0] rom_data [0:63];

    initial begin
        for (int i = 0; i < 64; i++) rom_data[i] = '0;
        $readmemh("config.hex", rom_data);
    end

    always_ff @(posedge clk) begin
        data_out <= rom_data[addr];
    end

endmodule
