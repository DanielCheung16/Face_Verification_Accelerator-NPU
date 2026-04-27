// ==============================================================================
// Module: mfn_addr_gen
// Description: Address generator with HWC layout and ping-pong support.
// ==============================================================================

module mfn_addr_gen #(
    parameter int AWIDTH = 32,
    parameter int M_ADDR_WIDTH = 18
)(
    input  logic                    clk,
    input  logic                    rst_n,
    
    input  logic                    reset_ptr,
    input  logic                    inc_write,
    input  logic                    ping_pong,  // 0: rd=0x00000,wr=0x10000; 1: rd=0x10000,wr=0x00000
    
    // Coordinates from Controller
    input  logic signed [8:0]       x_in,
    input  logic signed [8:0]       y_in,
    input  logic [9:0]              c_in,
    
    // Layer Params
    input  logic [7:0]              width_in,
    input  logic [7:0]              height_in,
    input  logic [9:0]              in_ch_in,
    
    output logic [M_ADDR_WIDTH-1:0] sram_rd_addr,
    output logic [M_ADDR_WIDTH-1:0] sram_wr_addr,
    output logic                    is_pad
);

    logic [M_ADDR_WIDTH-1:0] wr_ptr_reg;
    logic [M_ADDR_WIDTH-1:0]       calc_rd_addr;
    logic                    is_pad_comb;
    logic                    is_pad_reg;

    // Read/Write base addresses
    logic [M_ADDR_WIDTH-1:0] rd_base, wr_base;
    assign rd_base = ping_pong ? 19'h2A000 : 19'h00000;
    assign wr_base = ping_pong ? 19'h00000 : 19'h2A000;

    // 1. Padding Check
    always_comb begin
        if (x_in < 0 || x_in >= $signed({1'b0, width_in}) || 
            y_in < 0 || y_in >= $signed({1'b0, height_in})) begin
            is_pad_comb = 1'b1;
        end else begin
            is_pad_comb = 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) is_pad_reg <= 1'b0;
        else        is_pad_reg <= is_pad_comb;
    end

    assign is_pad = is_pad_reg;

    // 2. Read Address (HWC Layout): Addr = rd_base + (y * W + x) * InCh + c
    always_comb begin
        automatic logic signed [M_ADDR_WIDTH-1:0] row_offset;
        automatic logic signed [M_ADDR_WIDTH-1:0] pixel_offset;
        
        row_offset   = y_in * $signed({1'b0, width_in});
        pixel_offset = row_offset + x_in;
        calc_rd_addr = M_ADDR_WIDTH'(pixel_offset * $signed({1'b0, in_ch_in}) + $signed({1'b0, c_in}));
    end

    assign sram_rd_addr = rd_base + calc_rd_addr[M_ADDR_WIDTH-1:0];

    // 3. Write Address (Sequential with ping-pong base)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_reg <= '0;
        end else if (reset_ptr) begin
            wr_ptr_reg <= '0;
        end else if (inc_write) begin
            wr_ptr_reg <= wr_ptr_reg + 1'b1;
        end
    end

    assign sram_wr_addr = wr_base + wr_ptr_reg;

endmodule
