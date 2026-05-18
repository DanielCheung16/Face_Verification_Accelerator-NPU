// Address generator for the 3x3 spatial local-buffer load path.
//
// This module only generates the 9 activation/weight SRAM word addresses and
// padding-zero flags for one output window. Accumulation across input channels
// is intentionally outside this module.
//
// DW mode:
//   activation tile offset == output-channel tile offset
//   weight layout          == [3x3 position][channel tile]
//
// Conv3x3 mode:
//   activation tile offset == input-channel word offset
//   weight layout          == [input channel][3x3 position][output-channel tile]
//
// The arithmetic is kept as explicit assign/shift/add logic. The upper load
// controller captures the outputs before issuing SRAM reads, so this address
// setup logic is not on the steady-state SRAM read issue path.
module spatial_addr_gen #(
    parameter int ADDR_W = 16,

    localparam int NUM_POS = 9
) (
    input  logic [ADDR_W-1:0] act_base_addr_i,
    input  logic [ADDR_W-1:0] wgt_base_addr_i,
    input  logic [1:0] num_filter_code_i,  //0:64, 1:128, 2:256, 3:512
    input  logic [2:0] ifmap_size_code_i,  //0:7, 1:14, 2:28, 3:56, 4:112
    input  logic [ADDR_W-1:0] tile_offset_i,
    input  logic [ADDR_W-1:0] out_x_i,
    input  logic [ADDR_W-1:0] out_y_i,
    input  logic stride_i,
    input  logic pad_i,
    input  logic conv_mode_i,
    input  logic [ADDR_W-1:0] ic_offset_i,
    input  logic [3:0] input_channel_words_shift_i,

    // Registered setup constants from spatial_ld_controller.
    input  logic [ADDR_W-1:0] row_stride_i,
    input  logic [ADDR_W-1:0] pixel_stride_i,
    input  logic [ADDR_W-1:0] tile_offset_r_i,
    input  logic [ADDR_W-1:0] center_x_i,
    input  logic [ADDR_W-1:0] center_y_i,
    input  logic [3:0] num_filter_shift_i,
    input  logic [2:0] ifmap_size_code_r_i,
    input  logic conv_mode_r_i,
    input  logic [ADDR_W-1:0] ic_offset_r_i,
    input  logic [3:0] input_channel_words_shift_r_i,

    // Values captured by SETUP_CFG.
    output logic [ADDR_W-1:0] cfg_row_stride_o,
    output logic [ADDR_W-1:0] cfg_pixel_stride_o,
    output logic [ADDR_W-1:0] cfg_tile_offset_o,
    output logic [ADDR_W-1:0] cfg_center_x_o,
    output logic [ADDR_W-1:0] cfg_center_y_o,
    output logic [3:0] cfg_num_filter_shift_o,
    output logic [2:0] cfg_ifmap_size_code_o,
    output logic cfg_conv_mode_o,
    output logic [ADDR_W-1:0] cfg_ic_offset_o,
    output logic [3:0] cfg_input_channel_words_shift_o,

    // Values captured by SETUP_ADDR.
    output logic [ADDR_W-1:0] act_addr_o [NUM_POS],
    output logic [ADDR_W-1:0] wgt_addr_o [NUM_POS],
    output logic [NUM_POS-1:0] act_zero_o
);
    logic [ADDR_W-1:0] row0_base;
    logic [ADDR_W-1:0] row1_base;
    logic [ADDR_W-1:0] row2_base;
    logic [ADDR_W-1:0] wgt_row0_base;
    logic [ADDR_W-1:0] wgt_row1_base;
    logic [ADDR_W-1:0] wgt_row2_base;
    logic [ADDR_W-1:0] wgt_base_selected;
    logic [ADDR_W-1:0] ix0;
    logic [ADDR_W-1:0] ix1;
    logic [ADDR_W-1:0] ix2;
    logic [ADDR_W-1:0] iy0;
    logic [ADDR_W-1:0] iy1;
    logic [ADDR_W-1:0] iy2;
    logic [ADDR_W-1:0] ix0_x7;
    logic [ADDR_W-1:0] ix1_x7;
    logic [ADDR_W-1:0] ix2_x7;
    logic [ADDR_W-1:0] pixel_idx_x0;
    logic [ADDR_W-1:0] pixel_idx_x1;
    logic [ADDR_W-1:0] pixel_idx_x2;
    logic [ADDR_W-1:0] row0_offset;
    logic [ADDR_W-1:0] row1_offset;
    logic [ADDR_W-1:0] row2_offset;
    logic [ADDR_W-1:0] y0_offset;
    logic [ADDR_W-1:0] y1_offset;
    logic [ADDR_W-1:0] y2_offset;
    logic [ADDR_W-1:0] three_pixel_stride;
    logic [ADDR_W-1:0] ifmap_size;
    logic [3:0] cfg_output_words_shift;
    logic [3:0] cfg_act_words_shift;
    logic [3:0] act_pixel_shift;
    logic [ADDR_W-1:0] dw_act_tile_offset;
    logic [ADDR_W-1:0] conv_act_tile_offset;
    logic [ADDR_W-1:0] act_tile_offset;
    logic [ADDR_W-1:0] ic_x9;
    logic [ADDR_W-1:0] dw_wgt_base;
    logic [ADDR_W-1:0] conv_wgt_base;
    logic signed [ADDR_W:0] sx0;
    logic signed [ADDR_W:0] sy0;
    logic signed [ADDR_W:0] sx1;
    logic signed [ADDR_W:0] sy1;
    logic signed [ADDR_W:0] sx2;
    logic signed [ADDR_W:0] sy2;
    logic signed [ADDR_W:0] ifmap_size_s;

    // Global SRAM is addressed by 128-bit words. A channel tile is therefore
    // one address step, not 16 byte-address steps.
    assign cfg_output_words_shift = 4'd2 + {2'b0, num_filter_code_i};
    assign cfg_act_words_shift = conv_mode_i ? input_channel_words_shift_i : cfg_output_words_shift;
    assign cfg_num_filter_shift_o = cfg_output_words_shift;
    assign cfg_pixel_stride_o = ADDR_W'(4) << num_filter_code_i;
    assign ifmap_size = ADDR_W'(7) << ifmap_size_code_i;
    assign cfg_row_stride_o = ifmap_size << cfg_act_words_shift;
    assign cfg_tile_offset_o = tile_offset_i >> 4;
    assign cfg_center_x_o = stride_i ? (out_x_i << 1) : out_x_i;
    assign cfg_center_y_o = stride_i ? (out_y_i << 1) : out_y_i;
    assign cfg_ifmap_size_code_o = ifmap_size_code_i;
    assign cfg_conv_mode_o = conv_mode_i;
    assign cfg_ic_offset_o = ic_offset_i;
    assign cfg_input_channel_words_shift_o = input_channel_words_shift_i;

    assign sx0 = $signed({1'b0, center_x_i}) - $signed({{ADDR_W{1'b0}}, pad_i});
    assign sy0 = $signed({1'b0, center_y_i}) - $signed({{ADDR_W{1'b0}}, pad_i});
    assign sx1 = sx0 + {{ADDR_W{1'b0}}, 1'b1};
    assign sy1 = sy0 + {{ADDR_W{1'b0}}, 1'b1};
    assign sx2 = sx0 + {{(ADDR_W-1){1'b0}}, 2'd2};
    assign sy2 = sy0 + {{(ADDR_W-1){1'b0}}, 2'd2};
    assign ifmap_size_s = $signed({1'b0, ifmap_size});

    assign ix0 = sx0[ADDR_W-1:0];
    assign ix1 = sx1[ADDR_W-1:0];
    assign ix2 = sx2[ADDR_W-1:0];
    assign iy0 = sy0[ADDR_W-1:0];
    assign iy1 = sy1[ADDR_W-1:0];
    assign iy2 = sy2[ADDR_W-1:0];
    assign ix0_x7 = (ix0 << 3) - ix0;
    assign ix1_x7 = (ix1 << 3) - ix1;
    assign ix2_x7 = (ix2 << 3) - ix2;
    assign pixel_idx_x0 = ix0_x7 << ifmap_size_code_r_i;
    assign pixel_idx_x1 = ix1_x7 << ifmap_size_code_r_i;
    assign pixel_idx_x2 = ix2_x7 << ifmap_size_code_r_i;
    // DW mode keeps the old HWC channel-tile stride. Conv3x3 mode walks one
    // input-channel word group at a time, so activation addressing uses the
    // cached input-channel word count instead of output-channel count.
    assign act_pixel_shift = conv_mode_r_i ? input_channel_words_shift_r_i : num_filter_shift_i;
    assign dw_act_tile_offset = tile_offset_r_i;
    assign conv_act_tile_offset = ic_offset_r_i >> 4;
    assign act_tile_offset = conv_mode_r_i ? conv_act_tile_offset : dw_act_tile_offset;
    assign row0_offset = pixel_idx_x0 << act_pixel_shift;
    assign row1_offset = pixel_idx_x1 << act_pixel_shift;
    assign row2_offset = pixel_idx_x2 << act_pixel_shift;
    assign y0_offset = iy0 << act_pixel_shift;
    assign y1_offset = iy1 << act_pixel_shift;
    assign y2_offset = iy2 << act_pixel_shift;
    assign three_pixel_stride = pixel_stride_i + (pixel_stride_i << 1);

    assign row0_base = act_base_addr_i + row0_offset + act_tile_offset;
    assign row1_base = act_base_addr_i + row1_offset + act_tile_offset;
    assign row2_base = act_base_addr_i + row2_offset + act_tile_offset;

    assign act_addr_o[0] = row0_base + y0_offset;
    assign act_addr_o[1] = row0_base + y1_offset;
    assign act_addr_o[2] = row0_base + y2_offset;
    assign act_addr_o[3] = row1_base + y0_offset;
    assign act_addr_o[4] = row1_base + y1_offset;
    assign act_addr_o[5] = row1_base + y2_offset;
    assign act_addr_o[6] = row2_base + y0_offset;
    assign act_addr_o[7] = row2_base + y1_offset;
    assign act_addr_o[8] = row2_base + y2_offset;

    assign act_zero_o[0] = (sx0 < 0) || (sy0 < 0) || (sx0 >= ifmap_size_s) || (sy0 >= ifmap_size_s);
    assign act_zero_o[1] = (sx0 < 0) || (sy1 < 0) || (sx0 >= ifmap_size_s) || (sy1 >= ifmap_size_s);
    assign act_zero_o[2] = (sx0 < 0) || (sy2 < 0) || (sx0 >= ifmap_size_s) || (sy2 >= ifmap_size_s);
    assign act_zero_o[3] = (sx1 < 0) || (sy0 < 0) || (sx1 >= ifmap_size_s) || (sy0 >= ifmap_size_s);
    assign act_zero_o[4] = (sx1 < 0) || (sy1 < 0) || (sx1 >= ifmap_size_s) || (sy1 >= ifmap_size_s);
    assign act_zero_o[5] = (sx1 < 0) || (sy2 < 0) || (sx1 >= ifmap_size_s) || (sy2 >= ifmap_size_s);
    assign act_zero_o[6] = (sx2 < 0) || (sy0 < 0) || (sx2 >= ifmap_size_s) || (sy0 >= ifmap_size_s);
    assign act_zero_o[7] = (sx2 < 0) || (sy1 < 0) || (sx2 >= ifmap_size_s) || (sy1 >= ifmap_size_s);
    assign act_zero_o[8] = (sx2 < 0) || (sy2 < 0) || (sx2 >= ifmap_size_s) || (sy2 >= ifmap_size_s);

    // Conv3x3 weights are addressed as [ic][3x3 position][output-channel tile].
    // The ic*9 term is written as shifts/adds and then scaled by output-channel
    // tile count, avoiding a general multiplier in the load issue path.
    assign ic_x9 = (ic_offset_r_i << 3) + ic_offset_r_i;
    assign dw_wgt_base = wgt_base_addr_i + tile_offset_r_i;
    assign conv_wgt_base = wgt_base_addr_i + (ic_x9 << num_filter_shift_i) + tile_offset_r_i;
    assign wgt_base_selected = conv_mode_r_i ? conv_wgt_base : dw_wgt_base;
    assign wgt_row0_base = wgt_base_selected;
    assign wgt_row1_base = wgt_row0_base + three_pixel_stride;
    assign wgt_row2_base = wgt_row1_base + three_pixel_stride;

    assign wgt_addr_o[0] = wgt_row0_base;
    assign wgt_addr_o[1] = wgt_row0_base + pixel_stride_i;
    assign wgt_addr_o[2] = wgt_row0_base + (pixel_stride_i << 1);
    assign wgt_addr_o[3] = wgt_row1_base;
    assign wgt_addr_o[4] = wgt_row1_base + pixel_stride_i;
    assign wgt_addr_o[5] = wgt_row1_base + (pixel_stride_i << 1);
    assign wgt_addr_o[6] = wgt_row2_base;
    assign wgt_addr_o[7] = wgt_row2_base + pixel_stride_i;
    assign wgt_addr_o[8] = wgt_row2_base + (pixel_stride_i << 1);

`ifndef SYNTHESIS
    initial begin
        if (NUM_POS != 9) begin
            $fatal(1, "spatial_addr_gen assumes 9 positions for a 3x3 window");
        end
    end
`endif
endmodule
