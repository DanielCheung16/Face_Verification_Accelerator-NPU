// Weight buffer for spatial 3x3 engines.
//
// The buffer is organized as 9 independent banks, one bank for each kernel
// position. For DWConv3x3, each bank stores all channels of one kernel
// position, so one read address can return W00..W22 for the same channel.
module spatial_wgt_buffer #(
    parameter int DEPTH = 32,   // 32 * 128 bits = 512 bytes per kernel position
    parameter int WORD_W = 128,
    parameter int DATA_W = 8,

    localparam int NUM_BUF = 9,
    localparam int WR_POS_W = 4,
    localparam int BYTE_DEPTH = (WORD_W / DATA_W) * DEPTH,
    localparam int RD_ADDR_W = (BYTE_DEPTH <= 1) ? 1 : $clog2(BYTE_DEPTH)
) (
    input  logic clk,
    input  logic rst_n,

    // Clear all 9 banks before loading the next layer's weights.
    input  logic clear_i,

    // Sequential 128-bit weight load. wr_pos_i selects the kernel-position
    // bank. For a 512-channel depthwise layer, each position receives 32 words.
    //
    // Load protocol:
    //   word group 0: pos0, pos1, ... pos8  -> one complete 16-channel filter tile
    //   word group 1: pos0, pos1, ... pos8  -> next 16-channel filter tile
    //
    // weights_loaded_o means the current word group has all 9 kernel positions
    // loaded and may be read. It clears when the next word group starts loading.
    // all_weights_loaded_o means all DEPTH word groups are loaded.
    input  logic wr_en_i,
    input  logic [WR_POS_W-1:0] wr_pos_i,   // 0..8, referring to 3x3 kernel position
    input  logic [WORD_W-1:0] wr_data_i,
    output logic weights_loaded_o,
    output logic all_weights_loaded_o,

    // Byte read from all 9 kernel-position banks. rd_addr_i is the channel byte
    // index inside each bank; the 9 outputs feed spatial3x3_pe_array weights.
    input  logic rd_en_i,
    input  logic [RD_ADDR_W-1:0] rd_addr_i,
    output logic signed [DATA_W-1:0] rd_data_o  [NUM_BUF],
    output logic rd_valid_o                     [NUM_BUF]
);
`ifndef SYNTHESIS
    initial begin
        if (NUM_BUF != 9) begin
            $fatal(1, "spatial_wgt_buffer assumes 9 positions for a 3x3 kernel");
        end
        if (WORD_W % DATA_W != 0) begin
            $fatal(1, "spatial_wgt_buffer requires WORD_W to be an integer multiple of DATA_W");
        end
    end
`endif

    logic [NUM_BUF-1:0] tile_loaded_mask_r, tile_loaded_mask_w;
    logic [NUM_BUF-1:0] active_loaded_mask_w;
    logic [NUM_BUF-1:0] next_loaded_mask_w;
    logic weights_loaded_r, weights_loaded_w;
    logic all_weights_loaded_r, all_weights_loaded_w;
    logic [NUM_BUF-1:0] unit_wr_en_w;
    logic [NUM_BUF-1:0] unit_full_w;
    logic valid_wr_pos_w;
    logic can_accept_write_w;
    logic start_next_word_w;

    assign valid_wr_pos_w = (wr_pos_i < WR_POS_W'(NUM_BUF));
    assign weights_loaded_o = weights_loaded_r;
    assign all_weights_loaded_o = all_weights_loaded_r;

    generate
        for (genvar pos = 0; pos < NUM_BUF; pos++) begin : GEN_WGT_BANK
            local_byte_buffer #(
                .DATA_W(DATA_W),
                .WORD_W(WORD_W),
                .WORD_DEPTH(DEPTH)
            ) u_wgt_bank (
                .clk(clk),
                .rst_n(rst_n),
                .clear_i(clear_i),
                .wr_en_i(unit_wr_en_w[pos]),
                .wr_data_i(wr_data_i),
                .full_o(unit_full_w[pos]),
                .rd_en_i(rd_en_i),
                .rd_addr_i(rd_addr_i),
                .rd_data_o(rd_data_o[pos]),
                .rd_valid_o(rd_valid_o[pos])
            );
        end
    endgenerate

    always_comb begin
        tile_loaded_mask_w = tile_loaded_mask_r;
        weights_loaded_w = weights_loaded_r;
        all_weights_loaded_w = all_weights_loaded_r;
        unit_wr_en_w = '0;
        start_next_word_w = wr_en_i && valid_wr_pos_w && weights_loaded_r && !all_weights_loaded_o;
        active_loaded_mask_w = start_next_word_w ? '0 : tile_loaded_mask_r;
        next_loaded_mask_w = active_loaded_mask_w;
        can_accept_write_w = wr_en_i &&
                             valid_wr_pos_w &&
                             !all_weights_loaded_o &&
                             !active_loaded_mask_w[wr_pos_i];

        if (clear_i) begin
            tile_loaded_mask_w = '0;
            weights_loaded_w = 1'b0;
            all_weights_loaded_w = 1'b0;
        end else begin
            if (start_next_word_w) begin
                weights_loaded_w = 1'b0;
            end

            if (can_accept_write_w) begin
                unit_wr_en_w[wr_pos_i] = 1'b1;
                next_loaded_mask_w[wr_pos_i] = 1'b1;
                tile_loaded_mask_w = next_loaded_mask_w;
                weights_loaded_w = 1'b0;

                if (&next_loaded_mask_w) begin
                    tile_loaded_mask_w = '0;
                    weights_loaded_w = 1'b1;
                    // local_byte_buffer full_o means "this bank is currently
                    // writing its last word". Banks written earlier in this
                    // same group may already have wrapped, so do not use
                    // &unit_full_w here.
                    if (unit_full_w[wr_pos_i]) begin
                        all_weights_loaded_w = 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !clear_i && wr_en_i) begin
            if (!valid_wr_pos_w) begin
                $fatal(1, "spatial_wgt_buffer wr_pos_i=%0d is outside 0..8", wr_pos_i);
            end
            if (all_weights_loaded_o) begin
                $fatal(1, "spatial_wgt_buffer received write after all weight word groups were loaded");
            end
            if (valid_wr_pos_w && active_loaded_mask_w[wr_pos_i]) begin
                $fatal(1, "spatial_wgt_buffer duplicate write for kernel position %0d in the same word group", wr_pos_i);
            end
        end
    end
`endif

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_loaded_mask_r <= '0;
            weights_loaded_r <= 1'b0;
            all_weights_loaded_r <= 1'b0;
        end else begin
            tile_loaded_mask_r <= tile_loaded_mask_w;
            weights_loaded_r <= weights_loaded_w;
            all_weights_loaded_r <= all_weights_loaded_w;
        end
    end
endmodule
