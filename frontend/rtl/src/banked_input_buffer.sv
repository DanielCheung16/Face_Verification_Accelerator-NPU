//----------------------------------------------------------------------
//For this model:
//  - Write: can only write one DATA_W bits data into [x][y]
//  - Read:  can read BANK_NUM(map to ROW or COL) number of DATA_W bits out
//PS!!: This model has read-write conflict now ( but just keep in mind)
//----------------------------------------------------------------------

module banked_input_buffer #(
    parameter int BANK_NUM = 16,
    parameter int DATA_W   = 8,
    parameter int K_MAX    = 512,
    parameter int K_ADDR_W = (K_MAX <= 1) ? 1 : $clog2(K_MAX)
)(
    input  logic clk,

    // Read request.
    input  logic [K_ADDR_W-1:0] rd_idx_i   [BANK_NUM],
    input  logic                rd_valid_i [BANK_NUM],

    // 1-cycle registered read data.
    output logic signed [DATA_W-1:0] rd_data_o [BANK_NUM],

    // Simple preload/write interface for TB or upper loader.
    input  logic                        wr_en_i,
    input  logic [$clog2(BANK_NUM)-1:0] wr_bank_i,
    input  logic [K_ADDR_W-1:0]         wr_idx_i,
    input  logic signed [DATA_W-1:0]    wr_data_i
);

    logic signed [DATA_W-1:0] mem [BANK_NUM][K_MAX];

    always_ff @(posedge clk) begin
        if (wr_en_i) begin
            mem[wr_bank_i][wr_idx_i] <= wr_data_i;
        end

        for (int b = 0; b < BANK_NUM; b++) begin
            if (rd_valid_i[b]) begin
                rd_data_o[b] <= mem[b][rd_idx_i[b]];
            end
        end
    end

endmodule
