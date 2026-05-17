// Placeholder for the general Conv3x3 inside controller.
//
// This controller will own the Conv3x3-specific loops:
//   - output-channel tile counter
//   - input-channel counter
//   - partial-sum accumulation handshake
//
// It intentionally does not drive the current spatial3x3_dev yet. The wrapper
// keeps the public controller boundary stable while this controller is built.
module spatial_inside_controller_conv #(
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
    assign busy_o = 1'b0;
    assign done_o = 1'b0;
    assign clear_o = 1'b0;
    assign swap_o = 1'b0;
    assign tile_offset_o = '0;
    assign out_x_o = '0;
    assign out_y_o = '0;
    assign load_start_o = 1'b0;
    assign read_start_o = 1'b0;

    logic unused_inputs;
    assign unused_inputs = clk ^ rst_n ^ run_en_i ^ start_i ^
                           load_busy_i ^ load_done_i ^ read_busy_i ^ read_done_i ^
                           stride_i ^ ^current_num_filter_i ^ ^ifmap_size_code_i;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && start_i) begin
            $fatal(1, "spatial_inside_controller_conv is a placeholder and is not implemented yet");
        end
    end
`endif
endmodule
