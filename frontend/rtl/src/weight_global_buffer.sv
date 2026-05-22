module weight_global_buffer #(
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

    // Host/load port for programming weights.
    input  logic                  load_en_i,
    input  logic                  load_wr_en_i,
    input  logic [ADDR_W-1:0]     load_addr_i,
    input  logic [DATA_W-1:0]     load_wr_data_i,
    input  logic [WMASK_W-1:0]    load_wr_mask_i,
    output logic [DATA_W-1:0]     load_rd_data_o,

    // Accelerator read port.
    input  logic                  acc_rd_en_i,
    input  logic [ADDR_W-1:0]     acc_rd_addr_i,
    output logic [DATA_W-1:0]     acc_rd_data_o
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
                .a_en_i       (load_en_i),
                .a_wr_en_i    (load_wr_en_i),
                .a_addr_i     (load_addr_i),
                .a_wr_data_i  (load_wr_data_i),
                .a_wr_mask_i  (load_wr_mask_i),
                .a_rd_data_o  (load_rd_data_o),
                .b_en_i       (acc_rd_en_i),
                .b_wr_en_i    (1'b0),
                .b_addr_i     (acc_rd_addr_i),
                .b_wr_data_i  ('0),
                .b_wr_mask_i  ('0),
                .b_rd_data_o  (acc_rd_data_o)
            );
        end else begin : GEN_SDP
            assign load_rd_data_o = '0;
            sram_simple_dual_port_model #(
                .DATA_W(DATA_W),
                .DEPTH(DEPTH),
                .BYTE_W(BYTE_W),
                .ADDR_W(ADDR_W)
            ) u_sram (
                .clk        (clk),
                .rst_n      (rst_n),
                .wr_en_i    (load_en_i && load_wr_en_i),
                .wr_addr_i  (load_addr_i),
                .wr_data_i  (load_wr_data_i),
                .wr_mask_i  (load_wr_mask_i),
                .rd_en_i    (acc_rd_en_i),
                .rd_addr_i  (acc_rd_addr_i),
                .rd_data_o  (acc_rd_data_o)
            );
        end
    endgenerate
endmodule
