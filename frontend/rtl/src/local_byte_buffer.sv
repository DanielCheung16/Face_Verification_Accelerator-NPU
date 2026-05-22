// Generic local buffer for the spatial 3x3 engines.
//
// Write side:
//   - sequential WORD_W-bit writes
//   - clear_i resets the write pointer to word 0
//
// Read side:
//   - byte-addressed DATA_W-bit registered read
//   - rd_valid_o is rd_en_i delayed by one cycle
//
// Example mappings when WORD_W=128 and DATA_W=8:
//   - activation window buffer: WORD_DEPTH=1
//   - DW weight buffer:         WORD_DEPTH=32 for 512 bytes
module local_byte_buffer #(
    parameter int DATA_W = 8,
    parameter int WORD_W = 128,
    parameter int WORD_DEPTH = 9,

    localparam int LANES = WORD_W / DATA_W,         //the number of byte per word
    localparam int BYTE_DEPTH = WORD_DEPTH * LANES, //the number of the total byte
    localparam int WR_ADDR_W = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH),
    localparam int LANE_ADDR_W = (LANES <= 1) ? 1 : $clog2(LANES),
    localparam int RD_ADDR_W = (BYTE_DEPTH <= 1) ? 1 : $clog2(BYTE_DEPTH)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic clear_i,
    input  logic wr_en_i,
    input  logic [WORD_W-1:0] wr_data_i,
    output       full_o,

    input  logic rd_en_i,
    input  logic [RD_ADDR_W-1:0] rd_addr_i,
    output logic signed [DATA_W-1:0] rd_data_o,
    output logic rd_valid_o
);
`ifndef SYNTHESIS
    initial begin
        if (WORD_W % DATA_W != 0) begin
            $fatal(1, "local_byte_buffer requires WORD_W to be an integer multiple of DATA_W");
        end
        if (WORD_DEPTH < 1) begin
            $fatal(1, "local_byte_buffer requires WORD_DEPTH >= 1");
        end
    end
`endif

    (* ram_style = "block" *)
    logic [WORD_W-1:0] mem [0:WORD_DEPTH-1];
    logic [WR_ADDR_W-1:0] wr_ptr_r;

    logic [WR_ADDR_W-1:0] wr_addr_w;
    logic [WR_ADDR_W-1:0] wr_ptr_after_write_w;
    logic [WR_ADDR_W-1:0] rd_word_addr_w;
    logic [LANE_ADDR_W-1:0] rd_lane_addr_w;

    //set the write pointer to the header(address:0) if clear_i signal asserts 
    assign wr_addr_w = clear_i ? '0 : wr_ptr_r;

    //wr_ptr_after_write_w is the next pointer
    always_comb begin
        wr_ptr_after_write_w = wr_addr_w;
        if (wr_en_i) begin
            if (full_o) begin
                wr_ptr_after_write_w = '0;
            end else begin
                wr_ptr_after_write_w = wr_addr_w + WR_ADDR_W'(1);
            end
        end
    end

    assign rd_word_addr_w = WR_ADDR_W'(rd_addr_i / LANES);
    assign rd_lane_addr_w = LANE_ADDR_W'(rd_addr_i % LANES);

    always_ff @(posedge clk) begin
        if (rst_n && wr_en_i) begin
            mem[wr_addr_w] <= wr_data_i;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr_r <= '0;
            rd_data_o <= '0;
            rd_valid_o <= 1'b0;
        end else begin
            wr_ptr_r <= clear_i ? (wr_en_i ? wr_ptr_after_write_w : '0) : wr_ptr_after_write_w;

            rd_valid_o <= rd_en_i;
            if (rd_en_i) begin
                rd_data_o <= mem[rd_word_addr_w][rd_lane_addr_w*DATA_W +: DATA_W];
            end
        end
    end

    assign full_o = (wr_addr_w == WR_ADDR_W'(WORD_DEPTH - 1));
endmodule
