module sram_simple_dual_port_model #(
    parameter int DATA_W = 128,
    parameter int DEPTH  = 8192,
    parameter int BYTE_W = 8,
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter bit READ_DURING_WRITE_NEW_DATA = 1'b0,

    localparam int WMASK_W = (DATA_W + BYTE_W - 1) / BYTE_W
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Write port. This is a simple-dual-port SRAM model: one write-only port
    // and one independent read-only port.
    input  logic                  wr_en_i,
    input  logic [ADDR_W-1:0]     wr_addr_i,
    input  logic [DATA_W-1:0]     wr_data_i,
    input  logic [WMASK_W-1:0]    wr_mask_i,

    // Synchronous read port. rd_data_o is valid one cycle after rd_en_i.
    input  logic                  rd_en_i,
    input  logic [ADDR_W-1:0]     rd_addr_i,
    output logic [DATA_W-1:0]     rd_data_o
);
    logic [DATA_W-1:0] mem [DEPTH];

    function automatic logic [DATA_W-1:0] merge_masked_word(
        input logic [DATA_W-1:0] old_word,
        input logic [DATA_W-1:0] new_word,
        input logic [WMASK_W-1:0] mask
    );
        logic [DATA_W-1:0] merged;
        begin
            merged = old_word;
            for (int b = 0; b < WMASK_W; b++) begin
                if (mask[b]) begin
                    merged[b*BYTE_W +: BYTE_W] = new_word[b*BYTE_W +: BYTE_W];
                end
            end
            merge_masked_word = merged;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_data_o <= '0;
        end else begin
            if (rd_en_i) begin
                rd_data_o <= mem[rd_addr_i];
                if (READ_DURING_WRITE_NEW_DATA && wr_en_i && (wr_addr_i == rd_addr_i)) begin
                    rd_data_o <= merge_masked_word(mem[rd_addr_i], wr_data_i, wr_mask_i);
                end
            end

            if (wr_en_i) begin
                mem[wr_addr_i] <= merge_masked_word(mem[wr_addr_i], wr_data_i, wr_mask_i);
            end
        end
    end
endmodule
