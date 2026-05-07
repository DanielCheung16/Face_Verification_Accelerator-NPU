module sram_true_dual_port_model #(
    parameter int DATA_W = 128,
    parameter int DEPTH  = 8192,
    parameter int BYTE_W = 8,
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter bit READ_DURING_WRITE_NEW_DATA = 1'b0,

    localparam int WMASK_W = (DATA_W + BYTE_W - 1) / BYTE_W
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // True dual-port SRAM model: each port can read or write.
    input  logic                  a_en_i,
    input  logic                  a_wr_en_i,
    input  logic [ADDR_W-1:0]     a_addr_i,
    input  logic [DATA_W-1:0]     a_wr_data_i,
    input  logic [WMASK_W-1:0]    a_wr_mask_i,
    output logic [DATA_W-1:0]     a_rd_data_o,

    input  logic                  b_en_i,
    input  logic                  b_wr_en_i,
    input  logic [ADDR_W-1:0]     b_addr_i,
    input  logic [DATA_W-1:0]     b_wr_data_i,
    input  logic [WMASK_W-1:0]    b_wr_mask_i,
    output logic [DATA_W-1:0]     b_rd_data_o
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
            a_rd_data_o <= '0;
            b_rd_data_o <= '0;
        end else begin
            if (a_en_i && !a_wr_en_i) begin
                a_rd_data_o <= mem[a_addr_i];
                if (READ_DURING_WRITE_NEW_DATA && b_en_i && b_wr_en_i && (b_addr_i == a_addr_i)) begin
                    a_rd_data_o <= merge_masked_word(mem[a_addr_i], b_wr_data_i, b_wr_mask_i);
                end
            end

            if (b_en_i && !b_wr_en_i) begin
                b_rd_data_o <= mem[b_addr_i];
                if (READ_DURING_WRITE_NEW_DATA && a_en_i && a_wr_en_i && (a_addr_i == b_addr_i)) begin
                    b_rd_data_o <= merge_masked_word(mem[b_addr_i], a_wr_data_i, a_wr_mask_i);
                end
            end

            if (a_en_i && a_wr_en_i) begin
                mem[a_addr_i] <= merge_masked_word(mem[a_addr_i], a_wr_data_i, a_wr_mask_i);
            end

            if (b_en_i && b_wr_en_i) begin
                mem[b_addr_i] <= merge_masked_word(mem[b_addr_i], b_wr_data_i, b_wr_mask_i);
            end
        end
    end
endmodule
