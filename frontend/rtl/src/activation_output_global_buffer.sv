module activation_output_global_buffer #(
    parameter int DATA_W = 128,
    parameter int DEPTH  = 8192,
    parameter int BYTE_W = 8,
    parameter bit TRUE_DUAL_PORT = 1'b0,
    parameter string INIT_FILE = "none",
    parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),

    localparam int WMASK_W = (DATA_W + BYTE_W - 1) / BYTE_W
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Read port used by preload/residual paths. Address bit ADDR_W-1 can be
    // used by the scheduler as the activation/output ping-pong half select.
    input  logic                  rd_en_i,
    input  logic [ADDR_W-1:0]     rd_addr_i,
    output logic [DATA_W-1:0]     rd_data_o,

    // Writeback port from wr_controller.
    input  logic                  wr_en_i,
    input  logic [ADDR_W-1:0]     wr_addr_i,
    input  logic [DATA_W-1:0]     wr_data_i,
    input  logic [WMASK_W-1:0]    wr_mask_i,

    // Optional second RW port for debug/DMA/true-dual-port integration.
    input  logic                  aux_en_i,
    input  logic                  aux_wr_en_i,
    input  logic [ADDR_W-1:0]     aux_addr_i,
    input  logic [DATA_W-1:0]     aux_wr_data_i,
    input  logic [WMASK_W-1:0]    aux_wr_mask_i,
    output logic [DATA_W-1:0]     aux_rd_data_o
);
    generate
        if (TRUE_DUAL_PORT) begin : GEN_TDP
            sram_true_dual_port_model #(
                .DATA_W(DATA_W),
                .DEPTH(DEPTH),
                .BYTE_W(BYTE_W),
                .ADDR_W(ADDR_W),
                .INIT_FILE(INIT_FILE)
            ) u_sram (
                .clk          (clk),
                .rst_n        (rst_n),
                .a_en_i       (rd_en_i || wr_en_i),
                .a_wr_en_i    (wr_en_i),
                .a_addr_i     (wr_en_i ? wr_addr_i : rd_addr_i),
                .a_wr_data_i  (wr_data_i),
                .a_wr_mask_i  (wr_mask_i),
                .a_rd_data_o  (rd_data_o),
                .b_en_i       (aux_en_i),
                .b_wr_en_i    (aux_wr_en_i),
                .b_addr_i     (aux_addr_i),
                .b_wr_data_i  (aux_wr_data_i),
                .b_wr_mask_i  (aux_wr_mask_i),
                .b_rd_data_o  (aux_rd_data_o)
            );
        end else begin : GEN_SDP
            assign aux_rd_data_o = '0;
            sram_simple_dual_port_model #(
                .DATA_W(DATA_W),
                .DEPTH(DEPTH),
                .BYTE_W(BYTE_W),
                .ADDR_W(ADDR_W)
            ) u_sram (
                .clk        (clk),
                .rst_n      (rst_n),
                .wr_en_i    (wr_en_i),
                .wr_addr_i  (wr_addr_i),
                .wr_data_i  (wr_data_i),
                .wr_mask_i  (wr_mask_i),
                .rd_en_i    (rd_en_i),
                .rd_addr_i  (rd_addr_i),
                .rd_data_o  (rd_data_o)
            );
        end
    endgenerate
endmodule
