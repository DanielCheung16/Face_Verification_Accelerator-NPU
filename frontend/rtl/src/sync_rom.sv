// Generic synchronous 1-read-port ROM.
//
// Contract:
//   cycle N:   rd_en_i=1, rd_addr_i selects one ROM word
//   cycle N+1: rd_data_o holds the selected word
//
// The small INIT_* parameter list is intentional for current config ROM use.
// If the schedule grows, this module can be replaced by a generated ROM macro
// or extended to read an init file without changing its read protocol.
module sync_rom #(
    parameter int DATA_W = 32,
    parameter int DEPTH  = 2,
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),

    parameter logic [DATA_W-1:0] INIT_0 = '0,
    parameter logic [DATA_W-1:0] INIT_1 = '0,
    parameter logic [DATA_W-1:0] INIT_2 = '0,
    parameter logic [DATA_W-1:0] INIT_3 = '0,
    parameter logic [DATA_W-1:0] INIT_4 = '0,
    parameter logic [DATA_W-1:0] INIT_5 = '0,
    parameter logic [DATA_W-1:0] INIT_6 = '0,
    parameter logic [DATA_W-1:0] INIT_7 = '0
) (
    input  logic                  clk,
    input  logic                  rd_en_i,
    input  logic [ADDR_W-1:0]     rd_addr_i,
    output logic [DATA_W-1:0]     rd_data_o
);
    (* rom_style = "block", syn_romstyle = "block_rom" *)
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            mem[i] = '0;
        end

        if (DEPTH > 0) mem[0] = INIT_0;
        if (DEPTH > 1) mem[1] = INIT_1;
        if (DEPTH > 2) mem[2] = INIT_2;
        if (DEPTH > 3) mem[3] = INIT_3;
        if (DEPTH > 4) mem[4] = INIT_4;
        if (DEPTH > 5) mem[5] = INIT_5;
        if (DEPTH > 6) mem[6] = INIT_6;
        if (DEPTH > 7) mem[7] = INIT_7;
    end

    always_ff @(posedge clk) begin
        if (rd_en_i) begin
            rd_data_o <= mem[rd_addr_i];
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1) begin
            $fatal(1, "sync_rom requires DEPTH >= 1");
        end
        if (DEPTH > 8) begin
            $fatal(1, "sync_rom currently provides INIT_0..INIT_7 only");
        end
    end
`endif
endmodule
