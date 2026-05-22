// Quantization parameter memory.
//
// Storage policy:
//   - one output channel per read in each parameter bank
//   - common bank:   bias, requant multiplier, requant shift
//   - PReLU bank:    PReLU multiplier, PReLU shift
//   - residual bank: residual multiplier, residual shift, residual zero-point
//   - one-cycle read latency
//   - independent single-read-port ROMs so each field can infer a memory
//     with its natural width
//
// This module is global/shared. Layer-specific parameter schedulers inside
// conv1x1_top/spatial_top generate bank read addresses using layer_config_mem
// base addresses and their own output-channel order.
module quant_param_mem #(
    parameter int COMMON_PARAM_DEPTH = 9792,
    parameter int PRELU_PARAM_DEPTH = 9792,
    parameter int RESIDUAL_PARAM_DEPTH = 9792,
    parameter int PARAM_DEPTH = COMMON_PARAM_DEPTH,
    parameter int COMMON_PARAM_ADDR_W = (COMMON_PARAM_DEPTH <= 1) ? 1 : $clog2(COMMON_PARAM_DEPTH),
    parameter int PRELU_PARAM_ADDR_W = (PRELU_PARAM_DEPTH <= 1) ? 1 : $clog2(PRELU_PARAM_DEPTH),
    parameter int RESIDUAL_PARAM_ADDR_W = (RESIDUAL_PARAM_DEPTH <= 1) ? 1 : $clog2(RESIDUAL_PARAM_DEPTH),
    parameter int PARAM_ADDR_W = COMMON_PARAM_ADDR_W,
    parameter int BIAS_W = 64,
    parameter int MULT_W = 32,
    parameter int SHIFT_W = 6,

    parameter string BIAS_INIT_FILE = "",
    parameter string REQUANT_MULT_INIT_FILE = "",
    parameter string REQUANT_SHIFT_INIT_FILE = "",
    parameter string PRELU_MULT_INIT_FILE = "",
    parameter string PRELU_SHIFT_INIT_FILE = "",
    parameter string RESIDUAL_MULT_INIT_FILE = "",
    parameter string RESIDUAL_SHIFT_INIT_FILE = "",
    parameter string RESIDUAL_ZERO_POINT_INIT_FILE = ""
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                           common_rd_en_i,
    input  logic [COMMON_PARAM_ADDR_W-1:0] common_rd_addr_i,
    input  logic                           prelu_rd_en_i,
    input  logic [PRELU_PARAM_ADDR_W-1:0]  prelu_rd_addr_i,
    input  logic                           residual_rd_en_i,
    input  logic [RESIDUAL_PARAM_ADDR_W-1:0] residual_rd_addr_i,

    output logic                    common_rd_valid_o,
    output logic                    prelu_rd_valid_o,
    output logic                    residual_rd_valid_o,
    output logic signed [BIAS_W-1:0] bias_o,
    output logic signed [MULT_W-1:0] requant_multiplier_o,
    output logic [SHIFT_W-1:0]       requant_shift_o,
    output logic signed [MULT_W-1:0] prelu_multiplier_o,
    output logic [SHIFT_W-1:0]       prelu_shift_o,
    output logic signed [MULT_W-1:0] residual_multiplier_o,
    output logic [SHIFT_W-1:0]       residual_shift_o,
    output logic signed [BIAS_W-1:0] residual_zero_point_o
);
    logic [BIAS_W-1:0] bias_raw;
    logic [MULT_W-1:0] requant_multiplier_raw;
    logic [SHIFT_W-1:0] requant_shift_raw;
    logic [MULT_W-1:0] prelu_multiplier_raw;
    logic [SHIFT_W-1:0] prelu_shift_raw;
    logic [MULT_W-1:0] residual_multiplier_raw;
    logic [SHIFT_W-1:0] residual_shift_raw;
    logic [BIAS_W-1:0] residual_zero_point_raw;

    sync_rom #(
        .DATA_W(BIAS_W),
        .DEPTH(COMMON_PARAM_DEPTH),
        .ADDR_W(COMMON_PARAM_ADDR_W),
        .INIT_FILE(BIAS_INIT_FILE)
    ) u_bias_rom (
        .clk(clk),
        .rd_en_i(common_rd_en_i),
        .rd_addr_i(common_rd_addr_i),
        .rd_data_o(bias_raw)
    );

    sync_rom #(
        .DATA_W(MULT_W),
        .DEPTH(COMMON_PARAM_DEPTH),
        .ADDR_W(COMMON_PARAM_ADDR_W),
        .INIT_FILE(REQUANT_MULT_INIT_FILE)
    ) u_requant_mult_rom (
        .clk(clk),
        .rd_en_i(common_rd_en_i),
        .rd_addr_i(common_rd_addr_i),
        .rd_data_o(requant_multiplier_raw)
    );

    sync_rom #(
        .DATA_W(SHIFT_W),
        .DEPTH(COMMON_PARAM_DEPTH),
        .ADDR_W(COMMON_PARAM_ADDR_W),
        .INIT_FILE(REQUANT_SHIFT_INIT_FILE)
    ) u_requant_shift_rom (
        .clk(clk),
        .rd_en_i(common_rd_en_i),
        .rd_addr_i(common_rd_addr_i),
        .rd_data_o(requant_shift_raw)
    );

    sync_rom #(
        .DATA_W(MULT_W),
        .DEPTH(PRELU_PARAM_DEPTH),
        .ADDR_W(PRELU_PARAM_ADDR_W),
        .INIT_FILE(PRELU_MULT_INIT_FILE)
    ) u_prelu_mult_rom (
        .clk(clk),
        .rd_en_i(prelu_rd_en_i),
        .rd_addr_i(prelu_rd_addr_i),
        .rd_data_o(prelu_multiplier_raw)
    );

    sync_rom #(
        .DATA_W(SHIFT_W),
        .DEPTH(PRELU_PARAM_DEPTH),
        .ADDR_W(PRELU_PARAM_ADDR_W),
        .INIT_FILE(PRELU_SHIFT_INIT_FILE)
    ) u_prelu_shift_rom (
        .clk(clk),
        .rd_en_i(prelu_rd_en_i),
        .rd_addr_i(prelu_rd_addr_i),
        .rd_data_o(prelu_shift_raw)
    );

    sync_rom #(
        .DATA_W(MULT_W),
        .DEPTH(RESIDUAL_PARAM_DEPTH),
        .ADDR_W(RESIDUAL_PARAM_ADDR_W),
        .INIT_FILE(RESIDUAL_MULT_INIT_FILE)
    ) u_residual_mult_rom (
        .clk(clk),
        .rd_en_i(residual_rd_en_i),
        .rd_addr_i(residual_rd_addr_i),
        .rd_data_o(residual_multiplier_raw)
    );

    sync_rom #(
        .DATA_W(SHIFT_W),
        .DEPTH(RESIDUAL_PARAM_DEPTH),
        .ADDR_W(RESIDUAL_PARAM_ADDR_W),
        .INIT_FILE(RESIDUAL_SHIFT_INIT_FILE)
    ) u_residual_shift_rom (
        .clk(clk),
        .rd_en_i(residual_rd_en_i),
        .rd_addr_i(residual_rd_addr_i),
        .rd_data_o(residual_shift_raw)
    );

    sync_rom #(
        .DATA_W(BIAS_W),
        .DEPTH(RESIDUAL_PARAM_DEPTH),
        .ADDR_W(RESIDUAL_PARAM_ADDR_W),
        .INIT_FILE(RESIDUAL_ZERO_POINT_INIT_FILE)
    ) u_residual_zero_point_rom (
        .clk(clk),
        .rd_en_i(residual_rd_en_i),
        .rd_addr_i(residual_rd_addr_i),
        .rd_data_o(residual_zero_point_raw)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            common_rd_valid_o <= 1'b0;
            prelu_rd_valid_o <= 1'b0;
            residual_rd_valid_o <= 1'b0;
        end else begin
            common_rd_valid_o <= common_rd_en_i;
            prelu_rd_valid_o <= prelu_rd_en_i;
            residual_rd_valid_o <= residual_rd_en_i;
        end
    end

    assign bias_o = $signed(bias_raw);
    assign requant_multiplier_o = $signed(requant_multiplier_raw);
    assign requant_shift_o = requant_shift_raw;
    assign prelu_multiplier_o = $signed(prelu_multiplier_raw);
    assign prelu_shift_o = prelu_shift_raw;
    assign residual_multiplier_o = $signed(residual_multiplier_raw);
    assign residual_shift_o = residual_shift_raw;
    assign residual_zero_point_o = $signed(residual_zero_point_raw);

`ifndef SYNTHESIS
    initial begin
        if (COMMON_PARAM_DEPTH < 1 || PRELU_PARAM_DEPTH < 1 || RESIDUAL_PARAM_DEPTH < 1) begin
            $fatal(1, "quant_param_mem requires all parameter depths >= 1");
        end
        $display("[quant_param_mem] common_depth=%0d prelu_depth=%0d residual_depth=%0d total_bits=%0d",
                 COMMON_PARAM_DEPTH, PRELU_PARAM_DEPTH, RESIDUAL_PARAM_DEPTH,
                 COMMON_PARAM_DEPTH * (BIAS_W + MULT_W + SHIFT_W) +
                 PRELU_PARAM_DEPTH * (MULT_W + SHIFT_W) +
                 RESIDUAL_PARAM_DEPTH * (BIAS_W + MULT_W + SHIFT_W));
    end
`endif
endmodule
