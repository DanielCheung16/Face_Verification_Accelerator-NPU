// Wrapper for spatial 3x3 inside controllers.
//
// The external device protocol stays unified: spatial3x3_dev only sees this
// wrapper. Internally, DWConv3x3 and traditional Conv3x3 keep separate,
// readable controllers.
module spatial_inside_controller #(
    parameter int ADDR_W = 16,
    parameter int FILTER_CNT_W = 10,
    parameter int LANES = 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,
    input  logic start_i,

    output logic busy_o,
    output logic done_o,

    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,
    input  logic                    conv_mode_i,
    input  logic [FILTER_CNT_W-1:0] input_channel_count_i,
    input  logic [3:0]              input_channel_words_shift_i,
    input  logic [2:0] ifmap_size_code_i,
    input  logic stride_i,

    input  logic load_busy_i,
    input  logic load_done_i,
    input  logic read_busy_i,
    input  logic read_done_i,

    output logic              clear_o,
    output logic              swap_o,
    output logic [ADDR_W-1:0] tile_offset_o,
    output logic [ADDR_W-1:0] out_x_o,
    output logic [ADDR_W-1:0] out_y_o,
    output logic              conv_mode_o,
    output logic [ADDR_W-1:0] ic_offset_o,
    output logic [3:0]        input_channel_words_shift_o,
    output logic              load_start_o,
    output logic              read_start_o
);
    logic dw_busy;
    logic dw_done;
    logic dw_clear;
    logic dw_swap;
    logic [ADDR_W-1:0] dw_tile_offset;
    logic [ADDR_W-1:0] dw_out_x;
    logic [ADDR_W-1:0] dw_out_y;
    logic dw_load_start;
    logic dw_read_start;

    logic conv_busy;
    logic conv_done;
    logic conv_clear;
    logic conv_swap;
    logic [ADDR_W-1:0] conv_tile_offset;
    logic [ADDR_W-1:0] conv_out_x;
    logic [ADDR_W-1:0] conv_out_y;
    logic conv_mode;
    logic [ADDR_W-1:0] conv_ic_offset;
    logic [3:0] conv_input_channel_words_shift;
    logic conv_load_start;
    logic conv_read_start;

    spatial_inside_controller_dw #(
        .ADDR_W(ADDR_W),
        .FILTER_CNT_W(FILTER_CNT_W),
        .LANES(LANES)
    ) u_dw_controller (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i && !conv_mode_i),
        .busy_o(dw_busy),
        .done_o(dw_done),
        .current_num_filter_i(current_num_filter_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .load_busy_i(load_busy_i),
        .load_done_i(load_done_i),
        .read_busy_i(read_busy_i),
        .read_done_i(read_done_i),
        .clear_o(dw_clear),
        .swap_o(dw_swap),
        .tile_offset_o(dw_tile_offset),
        .out_x_o(dw_out_x),
        .out_y_o(dw_out_y),
        .load_start_o(dw_load_start),
        .read_start_o(dw_read_start)
    );

    spatial_inside_controller_conv #(
        .ADDR_W(ADDR_W),
        .FILTER_CNT_W(FILTER_CNT_W),
        .LANES(LANES)
    ) u_conv_controller (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i && conv_mode_i),
        .busy_o(conv_busy),
        .done_o(conv_done),
        .current_num_filter_i(current_num_filter_i),
        .input_channel_count_i(input_channel_count_i),
        .input_channel_words_shift_i(input_channel_words_shift_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .load_busy_i(load_busy_i),
        .load_done_i(load_done_i),
        .read_busy_i(read_busy_i),
        .read_done_i(read_done_i),
        .clear_o(conv_clear),
        .swap_o(conv_swap),
        .tile_offset_o(conv_tile_offset),
        .out_x_o(conv_out_x),
        .out_y_o(conv_out_y),
        .conv_mode_o(conv_mode),
        .ic_offset_o(conv_ic_offset),
        .input_channel_words_shift_o(conv_input_channel_words_shift),
        .load_start_o(conv_load_start),
        .read_start_o(conv_read_start)
    );

    always_comb begin
        if (conv_mode_i) begin
            busy_o = conv_busy;
            done_o = conv_done;
            clear_o = conv_clear;
            swap_o = conv_swap;
            tile_offset_o = conv_tile_offset;
            out_x_o = conv_out_x;
            out_y_o = conv_out_y;
            conv_mode_o = conv_mode;
            ic_offset_o = conv_ic_offset;
            input_channel_words_shift_o = conv_input_channel_words_shift;
            load_start_o = conv_load_start;
            read_start_o = conv_read_start;
        end else begin
            busy_o = dw_busy;
            done_o = dw_done;
            clear_o = dw_clear;
            swap_o = dw_swap;
            tile_offset_o = dw_tile_offset;
            out_x_o = dw_out_x;
            out_y_o = dw_out_y;
            conv_mode_o = 1'b0;
            ic_offset_o = '0;
            input_channel_words_shift_o = '0;
            load_start_o = dw_load_start;
            read_start_o = dw_read_start;
        end
    end

endmodule
