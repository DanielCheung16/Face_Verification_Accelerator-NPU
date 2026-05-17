module spatial3x3_dev #(
    parameter int ADDR_W = 16,
    parameter int WORD_W = 128,
    parameter int DATA_W = 8,
    parameter int ACC_W = 32,
    parameter int ACT_DEPTH = 1,
    parameter int WGT_DEPTH = 32,

    localparam int NUM_POS = 9,
    localparam int WGT_BYTE_DEPTH = (WORD_W / DATA_W) * WGT_DEPTH,
    localparam int WGT_RD_ADDR_W = (WGT_BYTE_DEPTH <= 1) ? 1 : $clog2(WGT_BYTE_DEPTH),
    localparam int FILTER_CNT_W = WGT_RD_ADDR_W + 1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_en_i,
    input  logic start_i,

    // Layer config from the layer switcher/testbench.
    input  logic [ADDR_W-1:0] act_base_addr_i,
    input  logic [ADDR_W-1:0] wgt_base_addr_i,
    input  logic [1:0] num_filter_code_i,       // 0:64, 1:128, 2:256, 3:512
    input  logic [2:0] ifmap_size_code_i,       // 0:7, 1:14, 2:28, 3:56, 4:112
    input  logic stride_i,                      // 0: stride=1, 1: stride=2
    input  logic pad_i,                         // 0: valid/no pad, 1: same pad
    input  logic [FILTER_CNT_W-1:0] current_num_filter_i,

    // Global A/O SRAM read.
    output logic gb_act_rd_en_o,
    output logic [ADDR_W-1:0] gb_act_rd_addr_o,
    input  logic [WORD_W-1:0] gb_act_rd_data_i,

    // Global Weight SRAM read.
    output logic gb_wgt_rd_en_o,
    output logic [ADDR_W-1:0] gb_wgt_rd_addr_o,
    input  logic [WORD_W-1:0] gb_wgt_rd_data_i,

    // Raw PE stream. Postprocess/writeback will sit after this device later.
    output logic signed [ACC_W-1:0] psum_o,
    output logic                    valid_o,
    output logic                    busy_o,
    output logic                    done_o
);
    logic clear;
    logic swap;
    logic load_start;
    logic read_start;
    logic [ADDR_W-1:0] tile_offset;
    logic [ADDR_W-1:0] out_x;
    logic [ADDR_W-1:0] out_y;

    logic load_busy;
    logic load_done;
    logic read_busy;
    logic read_done;
    logic filter_round_done;
    logic all_weights_loaded;
    logic window_valid;

    logic signed [DATA_W-1:0] activation [NUM_POS];
    logic signed [DATA_W-1:0] weight     [NUM_POS];

    spatial_inside_controller #(
        .ADDR_W(ADDR_W),
        .FILTER_CNT_W(FILTER_CNT_W),
        .LANES(WORD_W / DATA_W)
    ) u_spatial_inside_controller (
        .clk(clk),
        .rst_n(rst_n),
        .run_en_i(run_en_i),
        .start_i(start_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .current_num_filter_i(current_num_filter_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .stride_i(stride_i),
        .load_busy_i(load_busy),
        .load_done_i(load_done),
        .read_busy_i(read_busy),
        .read_done_i(read_done),
        .clear_o(clear),
        .swap_o(swap),
        .tile_offset_o(tile_offset),
        .out_x_o(out_x),
        .out_y_o(out_y),
        .load_start_o(load_start),
        .read_start_o(read_start)
    );

    window_generator #(
        .ADDR_W(ADDR_W),
        .WORD_W(WORD_W),
        .DATA_W(DATA_W),
        .ACT_DEPTH(ACT_DEPTH),
        .WGT_DEPTH(WGT_DEPTH)
    ) u_window_generator (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear),
        .swap_i(swap),
        .load_start_i(load_start),
        .read_start_i(read_start),
        .act_base_addr_i(act_base_addr_i),
        .wgt_base_addr_i(wgt_base_addr_i),
        .num_filter_code_i(num_filter_code_i),
        .ifmap_size_code_i(ifmap_size_code_i),
        .tile_offset_i(tile_offset),
        .out_x_i(out_x),
        .out_y_i(out_y),
        .stride_i(stride_i),
        .pad_i(pad_i),
        // Current DW path keeps these conv hooks idle. The later conv3x3
        // inside-controller will drive them when it schedules IC slices.
        .conv_mode_i(1'b0),
        .ic_offset_i('0),
        .input_channel_words_shift_i('0),
        .current_num_filter_i(current_num_filter_i),
        .gb_act_rd_en_o(gb_act_rd_en_o),
        .gb_act_rd_addr_o(gb_act_rd_addr_o),
        .gb_act_rd_data_i(gb_act_rd_data_i),
        .gb_wgt_rd_en_o(gb_wgt_rd_en_o),
        .gb_wgt_rd_addr_o(gb_wgt_rd_addr_o),
        .gb_wgt_rd_data_i(gb_wgt_rd_data_i),
        .activation_o(activation),
        .weight_o(weight),
        .valid_o(window_valid),
        .load_busy_o(load_busy),
        .load_done_o(load_done),
        .read_busy_o(read_busy),
        .read_done_o(read_done),
        .filter_round_done_o(filter_round_done),
        .all_weights_loaded_o(all_weights_loaded)
    );

    spatial3x3_pe_array #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_spatial3x3_pe_array (
        .clk(clk),
        .rst_n(rst_n),
        .enable_i(window_valid),
        .activation_i(activation),
        .weight_i(weight),
        .psum_o(psum_o),
        .valid_o(valid_o)
    );

`ifndef SYNTHESIS
    initial begin
        if (WORD_W != 128 || DATA_W != 8) begin
            $fatal(1, "spatial3x3_dev currently assumes 128-bit SRAM words and 8-bit lanes");
        end
    end
`endif
endmodule
