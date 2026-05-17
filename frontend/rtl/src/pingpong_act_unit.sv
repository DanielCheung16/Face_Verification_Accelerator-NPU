// Ping-pong activation window buffer for the spatial 3x3 engine.
//
// One buffer is read by the compute side while the other buffer is loaded with
// the next 3x3 window. The buffer does not swap automatically when loading is
// done, because the 9-cycle load can finish before the 16-cycle channel-tile
// compute. The outer controller owns the safe swap point.
module pingpong_act_unit #(
    parameter int DEPTH = 1,
    parameter int WORD_W = 128,
    parameter int DATA_W = 8,

    localparam int LANES = WORD_W / DATA_W,
    localparam int BYTE_DEPTH = LANES * DEPTH,
    localparam int RD_ADDR_W = (BYTE_DEPTH <= 1) ? 1 : $clog2(BYTE_DEPTH),
    localparam int LOAD_COUNT_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1)
) (
    input  logic clk,
    input  logic rst_n,

    // Resets the ping-pong state and prepares buffer 0 for the first load.
    input  logic clear_i,

    // Swap read/write buffers after current compute finishes and the next write
    // buffer is full. Do not assert with wr_en_i or rd_en_i.
    input  logic swap_i,

    // Sequential 128-bit window load into the current write buffer.
    input  logic wr_en_i,
    input  logic [WORD_W-1:0] wr_data_i,
    output logic wr_full_o,

    // Byte read from the current read buffer.
    input  logic rd_en_i,
    input  logic [RD_ADDR_W-1:0] rd_addr_i,
    output logic signed [DATA_W-1:0] rd_data_o,
    output logic rd_valid_o
);
    localparam int BUF_NUM = 2;

`ifndef SYNTHESIS
    initial begin
        if (WORD_W % DATA_W != 0) begin
            $fatal(1, "spatial_act_buffer requires WORD_W to be an integer multiple of DATA_W");
        end
        if (DEPTH < 1) begin
            $fatal(1, "spatial_act_buffer requires DEPTH >= 1");
        end
    end
`endif

    // wr_buf_r is the bank currently being loaded. rd_buf_r is the bank
    // currently visible to the PE-array read side.
    logic wr_buf_r, wr_buf_w;
    logic rd_buf_r, rd_buf_w;

    // Wrapper-level full flag. This is held until swap_i, so the controller can
    // wait for compute completion even if the next window load finished earlier.
    logic [LOAD_COUNT_W-1:0] wr_count_r, wr_count_w;
    logic wr_full_r, wr_full_w;

    logic clear_buf_w [BUF_NUM];
    logic wr_en_w [BUF_NUM];
    logic rd_en_w [BUF_NUM];
    // Connected for completeness/debug; ping-pong control uses wr_count_r so
    // "full" is held stable until swap_i.
    logic bank_full_w [BUF_NUM];
    logic signed [DATA_W-1:0] rd_data_w [BUF_NUM];
    logic rd_valid_w [BUF_NUM];

    assign wr_full_o = wr_full_r;

    generate
        for (genvar i = 0; i < BUF_NUM; i++) begin : GEN_SPATIAL_ACT_BUF
            local_byte_buffer #(
                .DATA_W(DATA_W),
                .WORD_W(WORD_W),
                .WORD_DEPTH(DEPTH)
            ) u_local_byte_buffer (
                .clk(clk),
                .rst_n(rst_n),
                .clear_i(clear_buf_w[i]),
                .wr_en_i(wr_en_w[i]),
                .wr_data_i(wr_data_i),
                .full_o(bank_full_w[i]),
                .rd_en_i(rd_en_w[i]),
                .rd_addr_i(rd_addr_i),
                .rd_data_o(rd_data_w[i]),
                .rd_valid_o(rd_valid_w[i])
            );
        end
    endgenerate

//pingpong  controller:
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_buf_r <= 1'b0;
            rd_buf_r <= 1'b1;
            wr_count_r <= '0;
            wr_full_r <= 1'b0;
        end else begin
            wr_buf_r <= wr_buf_w;
            rd_buf_r <= rd_buf_w;
            wr_count_r <= wr_count_w;
            wr_full_r <= wr_full_w;
        end
    end

    always_comb begin
        wr_buf_w = wr_buf_r;
        rd_buf_w = rd_buf_r;
        wr_count_w = wr_count_r;
        wr_full_w = wr_full_r;

        for (int i = 0; i < BUF_NUM; i++) begin
            clear_buf_w[i] = clear_i;
            wr_en_w[i] = 1'b0;
            rd_en_w[i] = 1'b0;
        end

        if (clear_i) begin
            wr_buf_w = 1'b0;
            rd_buf_w = 1'b1;
            wr_count_w = '0;
            wr_full_w = 1'b0;
        end else if (swap_i) begin
            // The old read bank becomes the next write bank. Clear it so the
            // following load starts from word 0.
            wr_buf_w = rd_buf_r;
            rd_buf_w = wr_buf_r;
            wr_count_w = '0;
            wr_full_w = 1'b0;
            clear_buf_w[rd_buf_r] = 1'b1;
        end else if (wr_en_i && !wr_full_r) begin
            // Sequentially fill the current write bank. Extra wr_en_i pulses are
            // ignored after the bank is full until the controller swaps banks.
            wr_en_w[wr_buf_r] = 1'b1;
            if (wr_count_r == LOAD_COUNT_W'(DEPTH - 1)) begin
                wr_count_w = wr_count_r;
                wr_full_w = 1'b1;
            end else begin
                wr_count_w = wr_count_r + LOAD_COUNT_W'(1);
            end
        end

        // Only the current read bank is exposed. local_byte_buffer returns data
        // and valid one cycle after rd_en_i.
        rd_en_w[rd_buf_r] = rd_en_i;
        rd_data_o = rd_data_w[rd_buf_r];
        rd_valid_o = rd_valid_w[rd_buf_r];
    end

endmodule
