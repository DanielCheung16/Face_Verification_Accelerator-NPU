// Quantization parameter memory.
//
// Storage policy:
//   - one channel per read
//   - one shared read address for all parameter fields
//   - one-cycle read latency
//   - five independent single-read-port ROMs so each field can infer a memory
//     with its natural width
//
// This module is global/shared. Layer-specific parameter schedulers inside
// conv1x1_top/spatial_top generate rd_addr_i using layer_config_mem base
// addresses and their own output-channel order.
module quant_param_mem #(
    parameter int PARAM_DEPTH = 9792,
    parameter int PARAM_ADDR_W = (PARAM_DEPTH <= 1) ? 1 : $clog2(PARAM_DEPTH),
    parameter int BIAS_W = 64,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,

    parameter logic [BIAS_W-1:0] INIT_BIAS_0 = '0,
    parameter logic [BIAS_W-1:0] INIT_BIAS_1 = '0,
    parameter logic [MULT_W-1:0] INIT_REQUANT_MULT_0 = MULT_W'(1),
    parameter logic [MULT_W-1:0] INIT_REQUANT_MULT_1 = MULT_W'(1),
    parameter logic [SHIFT_W-1:0] INIT_REQUANT_SHIFT_0 = '0,
    parameter logic [SHIFT_W-1:0] INIT_REQUANT_SHIFT_1 = '0,
    parameter logic [MULT_W-1:0] INIT_PRELU_MULT_0 = MULT_W'(1),
    parameter logic [MULT_W-1:0] INIT_PRELU_MULT_1 = MULT_W'(1),
    parameter logic [SHIFT_W-1:0] INIT_PRELU_SHIFT_0 = '0,
    parameter logic [SHIFT_W-1:0] INIT_PRELU_SHIFT_1 = '0
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                    rd_en_i,
    input  logic [PARAM_ADDR_W-1:0] rd_addr_i,

    output logic                    rd_valid_o,
    output logic signed [BIAS_W-1:0] bias_o,
    output logic signed [MULT_W-1:0] requant_multiplier_o,
    output logic [SHIFT_W-1:0]       requant_shift_o,
    output logic signed [MULT_W-1:0] prelu_multiplier_o,
    output logic [SHIFT_W-1:0]       prelu_shift_o
);
    logic [BIAS_W-1:0] bias_raw;
    logic [MULT_W-1:0] requant_multiplier_raw;
    logic [SHIFT_W-1:0] requant_shift_raw;
    logic [MULT_W-1:0] prelu_multiplier_raw;
    logic [SHIFT_W-1:0] prelu_shift_raw;

    sync_rom #(
        .DATA_W(BIAS_W),
        .DEPTH(PARAM_DEPTH),
        .ADDR_W(PARAM_ADDR_W),
        .INIT_0(INIT_BIAS_0),
        .INIT_1(INIT_BIAS_1)
    ) u_bias_rom (
        .clk(clk),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(bias_raw)
    );

    sync_rom #(
        .DATA_W(MULT_W),
        .DEPTH(PARAM_DEPTH),
        .ADDR_W(PARAM_ADDR_W),
        .INIT_0(INIT_REQUANT_MULT_0),
        .INIT_1(INIT_REQUANT_MULT_1)
    ) u_requant_mult_rom (
        .clk(clk),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(requant_multiplier_raw)
    );

    sync_rom #(
        .DATA_W(SHIFT_W),
        .DEPTH(PARAM_DEPTH),
        .ADDR_W(PARAM_ADDR_W),
        .INIT_0(INIT_REQUANT_SHIFT_0),
        .INIT_1(INIT_REQUANT_SHIFT_1)
    ) u_requant_shift_rom (
        .clk(clk),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(requant_shift_raw)
    );

    sync_rom #(
        .DATA_W(MULT_W),
        .DEPTH(PARAM_DEPTH),
        .ADDR_W(PARAM_ADDR_W),
        .INIT_0(INIT_PRELU_MULT_0),
        .INIT_1(INIT_PRELU_MULT_1)
    ) u_prelu_mult_rom (
        .clk(clk),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(prelu_multiplier_raw)
    );

    sync_rom #(
        .DATA_W(SHIFT_W),
        .DEPTH(PARAM_DEPTH),
        .ADDR_W(PARAM_ADDR_W),
        .INIT_0(INIT_PRELU_SHIFT_0),
        .INIT_1(INIT_PRELU_SHIFT_1)
    ) u_prelu_shift_rom (
        .clk(clk),
        .rd_en_i(rd_en_i),
        .rd_addr_i(rd_addr_i),
        .rd_data_o(prelu_shift_raw)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid_o <= 1'b0;
        end else begin
            rd_valid_o <= rd_en_i;
        end
    end

    assign bias_o = $signed(bias_raw);
    assign requant_multiplier_o = $signed(requant_multiplier_raw);
    assign requant_shift_o = requant_shift_raw;
    assign prelu_multiplier_o = $signed(prelu_multiplier_raw);
    assign prelu_shift_o = prelu_shift_raw;

`ifndef SYNTHESIS
    initial begin
        if (PARAM_DEPTH < 1) begin
            $fatal(1, "quant_param_mem requires PARAM_DEPTH >= 1");
        end
        $display("[quant_param_mem] DEPTH=%0d, total_bits=%0d",
                 PARAM_DEPTH, PARAM_DEPTH * (BIAS_W + (2 * MULT_W) + (2 * SHIFT_W)));
    end
`endif
endmodule
