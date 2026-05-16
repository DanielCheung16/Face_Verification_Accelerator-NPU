// Wrapper for spatial 3x3 inside controllers.
//
// The external device protocol stays unified: spatial3x3_dev only sees this
// wrapper. Internally, each layer family can keep its own readable controller.
// Current implementation locks to DWConv3x3 because the general Conv3x3
// controller still needs IC/OC scheduling and partial-sum accumulation support.
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
    output logic              load_start_o,
    output logic              read_start_o
);
    // TODO: promote this to a real mode input when spatial_inside_controller_conv
    // is connected. Keeping it local now avoids changing the device protocol
    // before the Conv3x3 accumulator path exists.
    localparam logic MODE_DWCONV3X3 = 1'b0;
    logic mode;

    assign mode = MODE_DWCONV3X3;

    generate
        if (MODE_DWCONV3X3 == 1'b0) begin : GEN_DW_CTRL
            spatial_inside_controller_dw #(
                .ADDR_W(ADDR_W),
                .FILTER_CNT_W(FILTER_CNT_W),
                .LANES(LANES)
            ) u_dw_controller (
                .clk(clk),
                .rst_n(rst_n),
                .run_en_i(run_en_i),
                .start_i(start_i),
                .busy_o(busy_o),
                .done_o(done_o),
                .current_num_filter_i(current_num_filter_i),
                .ifmap_size_code_i(ifmap_size_code_i),
                .stride_i(stride_i),
                .load_busy_i(load_busy_i),
                .load_done_i(load_done_i),
                .read_busy_i(read_busy_i),
                .read_done_i(read_done_i),
                .clear_o(clear_o),
                .swap_o(swap_o),
                .tile_offset_o(tile_offset_o),
                .out_x_o(out_x_o),
                .out_y_o(out_y_o),
                .load_start_o(load_start_o),
                .read_start_o(read_start_o)
            );
        end else begin : GEN_CONV_CTRL_PLACEHOLDER
            // This branch is intentionally unreachable for now. It documents
            // the wrapper boundary where the general Conv3x3 controller will
            // be attached without changing spatial3x3_dev.
            assign busy_o = 1'b0;
            assign done_o = start_i;
            assign clear_o = 1'b0;
            assign swap_o = 1'b0;
            assign tile_offset_o = '0;
            assign out_x_o = '0;
            assign out_y_o = '0;
            assign load_start_o = 1'b0;
            assign read_start_o = 1'b0;
        end
    endgenerate

    logic unused_mode;
    assign unused_mode = mode;

endmodule
