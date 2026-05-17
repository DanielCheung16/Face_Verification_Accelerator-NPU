module spatial_act_buffer #(
    parameter int DEPTH = 1,
    parameter int WORD_W = 128,
    parameter int DATA_W = 8,

    localparam int NUM_BUF = 9,
    localparam int WR_POS_W = 4,
    localparam int BYTE_DEPTH = (WORD_W / DATA_W) * DEPTH, //the number of the total byte
    localparam int RD_ADDR_W = (BYTE_DEPTH <= 1) ? 1 : $clog2(BYTE_DEPTH)
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
    input  logic [WR_POS_W-1:0] wr_pos_i,   // 0..8, referring to 3x3 window position
    input  logic [WORD_W-1:0] wr_data_i,
    output logic window_loaded_o,

    // Byte read from the current read buffer.
    input  logic rd_en_i,       //the rd_en should readout the 9 data simutaniouly
    input  logic [RD_ADDR_W-1:0] rd_addr_i,
    output logic signed [DATA_W-1:0] rd_data_o  [NUM_BUF],
    output logic rd_valid_o                     [NUM_BUF]
);
`ifndef SYNTHESIS
    initial begin
        if (NUM_BUF != 9) begin
            $fatal(1, "spatial_act_buffer assumes 9 positions for a 3x3 window");
        end
        if (WORD_W % DATA_W != 0) begin
            $fatal(1, "spatial_act_buffer requires WORD_W to be an integer multiple of DATA_W");
        end
    end
`endif

    logic [NUM_BUF-1:0] loaded_mask_r, loaded_mask_w;
    logic [NUM_BUF-1:0] unit_wr_en_w;
    logic [NUM_BUF-1:0] unit_full_w;
    logic valid_wr_pos_w;

    assign valid_wr_pos_w = (wr_pos_i < WR_POS_W'(NUM_BUF));
    assign window_loaded_o = &loaded_mask_r;

    generate
        for (genvar pos = 0; pos < NUM_BUF; pos++) begin : GEN_PINGPONG_ACT
            pingpong_act_unit #(
                .DEPTH(DEPTH),
                .WORD_W(WORD_W),
                .DATA_W(DATA_W)
            ) u_pingpong_act_unit (
                .clk(clk),
                .rst_n(rst_n),
                .clear_i(clear_i),
                .swap_i(swap_i),
                .wr_en_i(unit_wr_en_w[pos]),
                .wr_data_i(wr_data_i),
                .wr_full_o(unit_full_w[pos]),
                .rd_en_i(rd_en_i),
                .rd_addr_i(rd_addr_i),
                .rd_data_o(rd_data_o[pos]),
                .rd_valid_o(rd_valid_o[pos])
            );
        end
    endgenerate

    always_comb begin
        loaded_mask_w = loaded_mask_r;
        unit_wr_en_w = '0;

        if (clear_i || swap_i) begin
            // A new write-side 3x3 window starts after clear/swap.
            loaded_mask_w = '0;
        end else if (wr_en_i && valid_wr_pos_w) begin
            unit_wr_en_w[wr_pos_i] = 1'b1;
            loaded_mask_w[wr_pos_i] = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loaded_mask_r <= '0;
        end else begin
            loaded_mask_r <= loaded_mask_w;
        end
    end


endmodule
