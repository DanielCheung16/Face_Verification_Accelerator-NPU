// Generic synchronous 1-read-port ROM.
//
// Contract:
//   cycle N:   rd_en_i=1, rd_addr_i selects one ROM word
//   cycle N+1: rd_data_o holds the selected word
//
module sync_rom #(
    parameter int DATA_W = 32,
    parameter int DEPTH  = 2,
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter string INIT_FILE = ""
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

        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
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
    end
`endif
endmodule
