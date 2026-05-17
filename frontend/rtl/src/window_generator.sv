// Status to the spatial layer inside controller.
//
// load_busy_o:
//   Level. High while spatial_ld_controller is serving one load_start_i
//   request: setup address, issue 9 global reads/zero writes, and drain the
//   final 1-cycle SRAM read response.
//
// load_done_o:
//   One-cycle pulse. High when the current 3x3 load transaction has written
//   its last local-buffer entry. This is a transaction acknowledge for the
//   upper controller. It is not a read-start condition; internal
//   activation/weight buffer-ready levels are consumed inside this module.
//
// read_busy_o:
//   Level. High after read_start_i while spatial_rd_controller is armed or
//   issuing read commands. It does not mean valid_o is high; valid_o comes
//   from the local buffers' rd_valid_o.
//
// read_done_o:
//   One-cycle pulse per 16-lane read burst. It rises when the controller has
//   issued the 16th rd_en/rd_addr command for the current tile. It is not a
//   per-lane pulse.
//
// filter_round_done_o:
//   One-cycle pulse when the weight local-buffer read address reaches
//   current_num_filter_i-1 and wraps to 0. For our expected channel counts
//   this usually coincides with a read_done_o after several 16-lane tiles,
//   but it is a different boundary from "one 16-lane tile is done".
//
// all_weights_loaded_o:
//   Sticky level from spatial_wgt_buffer. High after all DEPTH weight word
//   groups have been loaded into the local weight buffer. It clears only on
//   clear_i.
//
// Internal ready levels:
//   window_loaded and weights_loaded are intentionally not exposed upward.
//   They only gate spatial_rd_controller so the upper layer controller does
//   not need to reason about local-buffer residency details.
module window_generator #(
    parameter int ADDR_W = 16,
    parameter int WORD_W = 128,
    parameter int DATA_W = 8,
    parameter int ACT_DEPTH = 1,
    parameter int WGT_DEPTH = 32,

    localparam int NUM_POS = 9,
    localparam int POS_W = 4,
    localparam int ACT_BYTE_DEPTH = (WORD_W / DATA_W) * ACT_DEPTH,
    localparam int ACT_RD_ADDR_W = (ACT_BYTE_DEPTH <= 1) ? 1 : $clog2(ACT_BYTE_DEPTH),
    localparam int WGT_BYTE_DEPTH = (WORD_W / DATA_W) * WGT_DEPTH,
    localparam int WGT_RD_ADDR_W = (WGT_BYTE_DEPTH <= 1) ? 1 : $clog2(WGT_BYTE_DEPTH)
) (
    input  logic clk,
    input  logic rst_n,

    // Control from the spatial layer inside controller.
    input  logic clear_i,
    input  logic swap_i,
    input  logic load_start_i,
    input  logic read_start_i,

    // Layer/window config from the upper controller.
    input  logic [ADDR_W-1:0] act_base_addr_i,
    input  logic [ADDR_W-1:0] wgt_base_addr_i,
    input  logic [1:0] num_filter_code_i,  //0:64, 1:128, 2:256, 3:512
    input  logic [2:0] ifmap_size_code_i,  //0:7, 1:14, 2:28, 3:56, 4:112
    input  logic [ADDR_W-1:0] tile_offset_i,
    input  logic [ADDR_W-1:0] out_x_i,
    input  logic [ADDR_W-1:0] out_y_i,
    input  logic stride_i,
    input  logic pad_i,
    input  logic conv_mode_i,                 // 0: DW, 1: traditional conv3x3
    input  logic [ADDR_W-1:0] ic_offset_i,    // input-channel slice for conv3x3
    input  logic [3:0] input_channel_words_shift_i,
    input  logic [WGT_RD_ADDR_W:0] current_num_filter_i,

    // Global A/O SRAM read.
    output logic gb_act_rd_en_o,
    output logic [ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic [WORD_W-1:0] gb_act_rd_data_i,

    // Global Weight SRAM read.
    output logic gb_wgt_rd_en_o,
    output logic [ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic [WORD_W-1:0] gb_wgt_rd_data_i,

    // Output to spatial3x3_pe_array.
    output logic signed [DATA_W-1:0] activation_o [NUM_POS],
    output logic signed [DATA_W-1:0] weight_o     [NUM_POS],
    output logic valid_o,

    // Status to the spatial layer inside controller.
    output logic load_busy_o,
    output logic load_done_o,
    output logic read_busy_o,
    output logic read_done_o,
    output logic filter_round_done_o,
    output logic all_weights_loaded_o
);
    logic act_wr_en;
    logic [POS_W-1:0] act_wr_pos;
    logic [WORD_W-1:0] act_wr_data;
    logic wgt_wr_en;
    logic [POS_W-1:0] wgt_wr_pos;
    logic [WORD_W-1:0] wgt_wr_data;

    logic rd_en;
    logic [ACT_RD_ADDR_W-1:0] rd_addr_act;
    logic [WGT_RD_ADDR_W-1:0] rd_addr_wgt;
    logic act_rd_valid [NUM_POS];
    logic wgt_rd_valid [NUM_POS];
    logic valid_all;
    logic window_loaded;
    logic weights_loaded;

    spatial_ld_controller #(
        .ADDR_W(ADDR_W),
        .WORD_W(WORD_W)
    ) u_spatial_ld_controller (
        .clk(clk),
        .rst_n(rst_n),
        .load_start_i(load_start_i),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .tile_offset_i(tile_offset_i),
        .out_x_i(out_x_i),
        .out_y_i(out_y_i),
        .stride_i(stride_i),
        .pad_i(pad_i),
        .conv_mode_i(conv_mode_i),
        .ic_offset_i(ic_offset_i),
        .input_channel_words_shift_i(input_channel_words_shift_i),
        .all_weights_loaded_i(all_weights_loaded_o),
        .gb_act_rd_en_o(gb_act_rd_en_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_en_o(gb_wgt_rd_en_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .act_wr_en_o(act_wr_en),
        .act_wr_pos_o(act_wr_pos),
        .act_wr_data_o(act_wr_data),
        .wgt_wr_en_o(wgt_wr_en),
        .wgt_wr_pos_o(wgt_wr_pos),
        .wgt_wr_data_o(wgt_wr_data),
        .load_busy_o(load_busy_o),
        .load_done_o(load_done_o)
    );

    spatial_rd_controller #(
        .ACT_DEPTH(ACT_DEPTH),
        .WGT_DEPTH(WGT_DEPTH)
    ) u_spatial_rd_controller (
        .clk(clk),
        .rst_n(rst_n),
        .read_start_i(read_start_i),
        .current_num_filter_i(current_num_filter_i),
        .window_loaded_i(window_loaded),
        .weights_loaded_i(weights_loaded),
        .all_weights_loaded_i(all_weights_loaded_o),
        .rd_en_o(rd_en),
        .rd_addr_act_o(rd_addr_act),
        .rd_addr_wgt_o(rd_addr_wgt),
        .read_busy_o(read_busy_o),
        .read_done_o(read_done_o),
        .filter_round_done_o(filter_round_done_o)
    );

    spatial_act_buffer #(
        .DEPTH(ACT_DEPTH),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W)
    ) u_spatial_act_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear_i),
        .swap_i(swap_i),
        .wr_en_i(act_wr_en),
        .wr_pos_i(act_wr_pos),
        .wr_data_i(act_wr_data),
        .window_loaded_o(window_loaded),
        .rd_en_i(rd_en),
        .rd_addr_i(rd_addr_act),
        .rd_data_o(activation_o),
        .rd_valid_o(act_rd_valid)
    );

    spatial_wgt_buffer #(
        .DEPTH(WGT_DEPTH),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W)
    ) u_spatial_wgt_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear_i),
        .wr_en_i(wgt_wr_en),
        .wr_pos_i(wgt_wr_pos),
        .wr_data_i(wgt_wr_data),
        .weights_loaded_o(weights_loaded),
        .all_weights_loaded_o(all_weights_loaded_o),
        .rd_en_i(rd_en),
        .rd_addr_i(rd_addr_wgt),
        .rd_data_o(weight_o),
        .rd_valid_o(wgt_rd_valid)
    );

    always_comb begin
        valid_all = 1'b1;
        for (int pos = 0; pos < NUM_POS; pos++) begin
            valid_all = valid_all && act_rd_valid[pos] && wgt_rd_valid[pos];
        end
    end

    assign valid_o = valid_all;

`ifndef SYNTHESIS
    initial begin
        if (WORD_W != 128 || DATA_W != 8) begin
            $fatal(1, "window_generator currently assumes 128-bit SRAM words and 8-bit lanes");
        end
        if (NUM_POS != 9) begin
            $fatal(1, "window_generator assumes 9 positions for a 3x3 window");
        end
    end
`endif
endmodule
